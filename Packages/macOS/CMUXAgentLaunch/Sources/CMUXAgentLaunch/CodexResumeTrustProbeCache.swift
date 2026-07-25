import CryptoKit
import Darwin
import Foundation

/// A process-shared coalescer for concurrent Codex effective-config probes.
///
/// Restoring several panes launches one wrapper process per pane. Equivalent
/// wrappers use one of 256 stable lock shards so only one process runs the
/// heavyweight app-server probe; waiters wake on the owner's atomic handoff
/// write and read that record. A process that acquires the lock
/// without first observing contention always probes again, so explicit config
/// changes are visible to the next invocation instead of being hidden by a
/// time-based cache.
public struct CodexResumeTrustProbeCache: Sendable {
    private static let cacheLifetime: TimeInterval = 5
    private static let maximumEntryCount = 64
    private static let maximumRecordBytes = 1_048_576
    private static let maximumDecisionPathCount = 8_192
    private static let lockShardCount = 256
    private static let lockWait: Duration = .seconds(2)

    private let directory: URL
    // SAFETY: FileManager's filesystem methods are thread-safe, and this value
    // is immutable after construction. Cross-process mutation is serialized by
    // the kernel file lock rather than mutable FileManager state.
    private nonisolated(unsafe) let fileManager: FileManager

    /// Creates a cache rooted in a cmux-owned state directory.
    ///
    /// - Parameters:
    ///   - directory: The cmux-owned directory for lock and handoff files.
    ///   - fileManager: The filesystem dependency used for cache operations.
    public init(directory: URL, fileManager: FileManager) {
        self.directory = directory
        self.fileManager = fileManager
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
            return await probe()
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
        let lockFD = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard lockFD >= 0 else {
            return await probe()
        }
        defer { Darwin.close(lockFD) }

        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EINTR else {
                return await probe()
            }
            if lockError == EWOULDBLOCK {
                let handoff = await waitForConcurrentHandoff(
                    at: cacheURL,
                    key: key
                )
                if handoff.found {
                    return handoff.value
                }
                // The owner may be suspended indefinitely. Run an independent,
                // already-bounded app-server probe instead of blocking resume.
                return await probe()
            }
        }
        defer { _ = flock(lockFD, LOCK_UN) }

        try? fileManager.removeItem(at: cacheURL)
        let result = await probe()
        prune(now: Date())
        write(result, key: key, to: cacheURL)
        return result
    }

    private enum HandoffWaitResult: Sendable {
        case found(Set<String>?)
        case unavailable
    }

    /// Waits on directory changes from the kernel while the current probe
    /// owner writes its atomic handoff. The paired clock task is cancellable,
    /// so a suspended owner cannot hold restored sessions indefinitely.
    private func waitForConcurrentHandoff(
        at cacheURL: URL,
        key: String
    ) async -> (found: Bool, value: Set<String>?) {
        guard let changes = directoryChangeEvents() else {
            return (false, nil)
        }

        let initial = lookup(at: cacheURL, key: key, now: Date())
        if initial.found {
            return initial
        }

        return await withTaskGroup(of: HandoffWaitResult.self) { group in
            group.addTask {
                for await _ in changes {
                    guard !Task.isCancelled else {
                        return .unavailable
                    }
                    let handoff = lookup(
                        at: cacheURL,
                        key: key,
                        now: Date()
                    )
                    if handoff.found {
                        return .found(handoff.value)
                    }
                }
                return .unavailable
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: Self.lockWait)
                } catch {
                    return .unavailable
                }
                return .unavailable
            }

            let result = await group.next() ?? .unavailable
            group.cancelAll()
            switch result {
            case .found(let value):
                return (true, value)
            case .unavailable:
                return (false, nil)
            }
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
