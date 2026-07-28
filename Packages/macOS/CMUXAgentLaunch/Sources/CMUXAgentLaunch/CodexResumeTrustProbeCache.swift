import CryptoKit
import Darwin
import Foundation

/// A process-shared coalescer for concurrent Codex effective-config probes.
///
/// Restoring several panes launches one wrapper process per pane. Equivalent
/// wrappers use one of 256 stable lock shards so only one process runs the
/// heavyweight app-server probe for an equivalent key. Four process-shared
/// slots cap probes across different keys. Waiters wake on either their matching
/// atomic handoff or an explicit release generation, and fail closed at the
/// full owner bound instead of starting duplicate probes. A process that
/// acquires its key lock without first observing contention always probes again,
/// so explicit config changes remain visible to the next invocation.
public struct CodexResumeTrustProbeCache: Sendable {
    private static let cacheLifetime: TimeInterval = 5
    private static let maximumEntryCount = 64
    private static let maximumRecordBytes = 1_048_576
    private static let maximumDecisionPathCount = 8_192
    private static let lockShardCount = 256
    private static let defaultKeyWait: Duration = .seconds(24)
    private static let defaultProbeSlotWait: Duration = .seconds(12)
    private static let defaultProbeSlotCount = 4

    private let directory: URL
    // SAFETY: FileManager's filesystem methods are thread-safe, and this value
    // is immutable after construction. Cross-process mutation is serialized by
    // the kernel file lock rather than mutable FileManager state.
    private nonisolated(unsafe) let fileManager: FileManager
    private let contentionObserver: (@Sendable () -> Void)?
    private let keyWait: Duration
    private let probeSlotWait: Duration
    private let probeSlotCount: Int

    /// Creates a cache rooted in a cmux-owned state directory.
    ///
    /// - Parameters:
    ///   - directory: The cmux-owned directory for lock and handoff files.
    ///   - fileManager: The filesystem dependency used for cache operations.
    public init(directory: URL, fileManager: FileManager) {
        self.directory = directory
        self.fileManager = fileManager
        self.contentionObserver = nil
        self.keyWait = Self.defaultKeyWait
        self.probeSlotWait = Self.defaultProbeSlotWait
        self.probeSlotCount = Self.defaultProbeSlotCount
    }

    init(
        directory: URL,
        fileManager: FileManager,
        keyWait: Duration = Self.defaultKeyWait,
        probeSlotWait: Duration = Self.defaultProbeSlotWait,
        probeSlotCount: Int = Self.defaultProbeSlotCount,
        contentionObserver: (@Sendable () -> Void)? = nil
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.contentionObserver = contentionObserver
        self.keyWait = keyWait
        self.probeSlotWait = probeSlotWait
        self.probeSlotCount = min(max(probeSlotCount, 1), 16)
    }

    /// Returns coalesced or freshly probed project decision paths.
    ///
    /// `nil` remains the fail-closed result. Key components identify equivalent
    /// probes that may run concurrently during one multi-pane restore.
    public func resolve(
        keyComponents: [String],
        probe: () async -> Set<String>?
    ) async -> Set<String>? {
        guard prepareDirectory() else {
            return nil
        }

        let key = cacheKey(components: keyComponents)
        let cacheURL = directory.appendingPathComponent(
            "\(key).json",
            isDirectory: false
        )
        let shard = Int(key.prefix(2), radix: 16) ?? 0
        let shardText = String(shard)
        let paddedShard = String(
            repeating: "0",
            count: max(0, 3 - shardText.count)
        ) + shardText
        let lockURL = directory.appendingPathComponent(
            "lock-\(paddedShard)-of-\(Self.lockShardCount)",
            isDirectory: false
        )
        let releaseURL = directory.appendingPathComponent(
            "release-\(paddedShard)-of-\(Self.lockShardCount)",
            isDirectory: false
        )
        let lockFD = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard lockFD >= 0 else {
            return nil
        }
        defer { Darwin.close(lockFD) }

        let clock = ContinuousClock()
        let lockDeadline = clock.now.advanced(by: keyWait)
        var observedReleaseGeneration = shardReleaseGeneration(at: releaseURL)
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EINTR else {
                return nil
            }
            if lockError == EWOULDBLOCK {
                contentionObserver?()
                guard clock.now < lockDeadline else {
                    return nil
                }
                let handoff = await waitForConcurrentHandoff(
                    at: cacheURL,
                    key: key,
                    releaseURL: releaseURL,
                    after: observedReleaseGeneration,
                    clock: clock,
                    deadline: lockDeadline
                )
                if handoff.found {
                    return handoff.value
                }
                if handoff.shardReleased {
                    observedReleaseGeneration = handoff.releaseGeneration
                    continue
                }
                // A suspended owner must not turn one restore burst into an
                // unbounded probe herd. The caller fails closed after the full
                // owner bound and Codex keeps its own trust picker.
                return nil
            }
        }
        defer {
            _ = flock(lockFD, LOCK_UN)
            publishShardRelease(at: releaseURL)
        }

        try? fileManager.removeItem(at: cacheURL)
        let slotDeadline = clock.now.advanced(by: probeSlotWait)
        guard let probeSlotFD = await acquireProbeSlot(
            clock: clock,
            deadline: slotDeadline
        ) else {
            prune(now: Date())
            write(nil, key: key, to: cacheURL)
            return nil
        }
        defer {
            _ = flock(probeSlotFD, LOCK_UN)
            Darwin.close(probeSlotFD)
            publishProbeSlotRelease()
        }
        let result = await probe()
        prune(now: Date())
        write(result, key: key, to: cacheURL)
        return result
    }

    /// Waits on directory changes from the kernel while the current probe
    /// owner writes its atomic handoff. The paired clock task is cancellable,
    /// so a suspended owner cannot hold restored sessions indefinitely.
    private func waitForConcurrentHandoff(
        at cacheURL: URL,
        key: String,
        releaseURL: URL,
        after observedReleaseGeneration: String?,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async -> (
        found: Bool,
        value: Set<String>?,
        shardReleased: Bool,
        releaseGeneration: String?
    ) {
        guard let changes = directoryChangeEvents() else {
            return (false, nil, false, observedReleaseGeneration)
        }

        let initial = lookup(at: cacheURL, key: key, now: Date())
        if initial.found {
            return (true, initial.value, false, observedReleaseGeneration)
        }
        let initialGeneration = shardReleaseGeneration(at: releaseURL)
        if initialGeneration != observedReleaseGeneration {
            return (false, nil, true, initialGeneration)
        }

        return await withTaskGroup(
            of: (
                found: Bool,
                value: Set<String>?,
                shardReleased: Bool,
                releaseGeneration: String?
            ).self
        ) { group in
            group.addTask {
                for await _ in changes {
                    guard !Task.isCancelled else {
                        return (
                            false,
                            nil,
                            false,
                            observedReleaseGeneration
                        )
                    }
                    let handoff = lookup(
                        at: cacheURL,
                        key: key,
                        now: Date()
                    )
                    if handoff.found {
                        return (
                            true,
                            handoff.value,
                            false,
                            observedReleaseGeneration
                        )
                    }
                    let releaseGeneration = shardReleaseGeneration(
                        at: releaseURL
                    )
                    if releaseGeneration != observedReleaseGeneration {
                        return (false, nil, true, releaseGeneration)
                    }
                }
                return (false, nil, false, observedReleaseGeneration)
            }
            group.addTask {
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return (false, nil, false, observedReleaseGeneration)
                }
                return (false, nil, false, observedReleaseGeneration)
            }

            let result = await group.next()
                ?? (false, nil, false, observedReleaseGeneration)
            group.cancelAll()
            return result
        }
    }

    /// Acquires one process-shared probe slot without blocking an executor
    /// thread. Slot release writes a generation file, which wakes queued keys
    /// through the same vnode stream used by key handoffs.
    private func acquireProbeSlot(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async -> Int32? {
        let releaseURL = directory.appendingPathComponent(
            "probe-slot-release",
            isDirectory: false
        )
        var observedReleaseGeneration = shardReleaseGeneration(at: releaseURL)

        while clock.now < deadline {
            for index in 0..<probeSlotCount {
                let slotURL = directory.appendingPathComponent(
                    String(
                        format: "probe-slot-%02d-of-%02d",
                        index,
                        probeSlotCount
                    ),
                    isDirectory: false
                )
                let fd = Darwin.open(
                    slotURL.path,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
                guard fd >= 0 else { continue }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    return fd
                }
                Darwin.close(fd)
            }

            guard let generation = await waitForGenerationChange(
                at: releaseURL,
                after: observedReleaseGeneration,
                clock: clock,
                deadline: deadline
            ) else {
                return nil
            }
            observedReleaseGeneration = generation
        }
        return nil
    }

    private func waitForGenerationChange(
        at url: URL,
        after observedGeneration: String?,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        let initialGeneration = shardReleaseGeneration(at: url)
        if initialGeneration != observedGeneration {
            return initialGeneration
        }
        guard let changes = directoryChangeEvents() else {
            return nil
        }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await _ in changes {
                    guard !Task.isCancelled else { return nil }
                    let generation = shardReleaseGeneration(at: url)
                    if generation != observedGeneration {
                        return generation
                    }
                }
                return nil
            }
            group.addTask {
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return nil
                }
                return nil
            }
            let generation = await group.next() ?? nil
            group.cancelAll()
            return generation
        }
    }

    private func publishProbeSlotRelease() {
        publishShardRelease(
            at: directory.appendingPathComponent(
                "probe-slot-release",
                isDirectory: false
            )
        )
    }

    private func shardReleaseGeneration(at url: URL) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
            let size = (attributes[.size] as? NSNumber)?.intValue,
            size <= 128,
            let generation = try? String(contentsOf: url, encoding: .utf8),
            !generation.isEmpty,
            generation.utf8.count <= 128 else {
            return nil
        }
        return generation
    }

    private func publishShardRelease(at url: URL) {
        do {
            try UUID().uuidString.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Bridges Darwin's vnode callback into a cancellation-aware async stream.
    /// DispatchSource is required at this low-level filesystem boundary; all
    /// cache state remains immutable and is read by the awaiting task.
    private func directoryChangeEvents() -> AsyncStream<Void>? {
        let directoryFD = Darwin.open(
            directory.path,
            O_EVTONLY | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            return nil
        }

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directoryFD,
                eventMask: [.write, .rename, .delete],
                queue: nil
            )
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                Darwin.close(directoryFD)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }
    }

    private func prepareDirectory() -> Bool {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            return true
        } catch {
            return false
        }
    }

    private func cacheKey(components: [String]) -> String {
        let digest = SHA256.hash(
            data: Data(components.joined(separator: "\u{0}").utf8)
        )
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(64)
        for byte in digest {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func lookup(
        at url: URL,
        key: String,
        now: Date
    ) -> (found: Bool, value: Set<String>?) {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
            let size = (attributes[.size] as? NSNumber)?.intValue,
            size <= Self.maximumRecordBytes,
            let data = try? Data(contentsOf: url),
            let record = try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            record["version"] as? Int == 1,
            record["key"] as? String == key,
            let createdAt = record["createdAt"] as? TimeInterval,
            let succeeded = record["succeeded"] as? Bool,
            let decisionPaths = record["decisionPaths"] as? [String],
            decisionPaths.count <= Self.maximumDecisionPathCount
        else {
            return (false, nil)
        }
        let age = now.timeIntervalSince1970 - createdAt
        guard age >= 0, age <= Self.cacheLifetime else {
            try? fileManager.removeItem(at: url)
            return (false, nil)
        }
        return (true, succeeded ? Set(decisionPaths) : nil)
    }

    private func write(
        _ result: Set<String>?,
        key: String,
        to url: URL
    ) {
        let record: [String: Any] = [
            "version": 1,
            "key": key,
            "createdAt": Date().timeIntervalSince1970,
            "succeeded": result != nil,
            "decisionPaths": result?.sorted() ?? [],
        ]
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(
                  withJSONObject: record,
                  options: [.sortedKeys]
              ),
              data.count <= Self.maximumRecordBytes else {
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            try? fileManager.removeItem(at: url)
        }
    }

    private func prune(now: Date) {
        let urls = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }

        var current: [(url: URL, createdAt: TimeInterval)] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  data.count <= Self.maximumRecordBytes,
                  let record = try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: Any],
                  record["version"] as? Int == 1,
                  let createdAt = record["createdAt"] as? TimeInterval,
                  let decisionPaths = record["decisionPaths"] as? [String],
                  decisionPaths.count <= Self.maximumDecisionPathCount,
                  now.timeIntervalSince1970 - createdAt >= 0,
                  now.timeIntervalSince1970 - createdAt <= Self.cacheLifetime else {
                try? fileManager.removeItem(at: url)
                continue
            }
            current.append((url, createdAt))
        }

        if current.count > Self.maximumEntryCount {
            current.sort { $0.createdAt > $1.createdAt }
            for entry in current.dropFirst(Self.maximumEntryCount) {
                try? fileManager.removeItem(at: entry.url)
            }
        }
    }
}
