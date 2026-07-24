import CryptoKit
import Darwin
import Foundation

/// A process-shared coalescer for concurrent Codex effective-config probes.
///
/// Restoring several panes launches one wrapper process per pane. Equivalent
/// wrappers use one of 256 stable lock shards so only one process runs the
/// heavyweight app-server probe; waiters wake when the kernel lock is released
/// and then read its atomic handoff record. A process that acquires the lock
/// without first observing contention always probes again, so explicit config
/// changes are visible to the next invocation instead of being hidden by a
/// time-based cache.
public struct CodexResumeTrustProbeCache: Sendable {
    private static let cacheLifetime: TimeInterval = 5
    private static let maximumEntryCount = 64
    private static let maximumRecordBytes = 1_048_576
    private static let maximumDecisionPathCount = 8_192
    private static let lockShardCount = 256
    private static let lockWaitNanoseconds: UInt64 = 2_000_000_000
    private static let lockRetryMicroseconds: useconds_t = 10_000

    private let directory: URL

    /// Creates a cache rooted in a cmux-owned state directory.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Returns coalesced or freshly probed project decision paths.
    ///
    /// `nil` remains the fail-closed result. Key components identify equivalent
    /// probes that may run concurrently during one multi-pane restore.
    public func resolve(
        keyComponents: [String],
        probe: () -> Set<String>?
    ) -> Set<String>? {
        guard prepareDirectory() else {
            return probe()
        }

        let key = cacheKey(components: keyComponents)
        let cacheURL = directory.appendingPathComponent(
            "\(key).json",
            isDirectory: false
        )
        let shard = Int(key.prefix(2), radix: 16) ?? 0
        let lockURL = directory.appendingPathComponent(
            String(format: "lock-%03d-of-%03d", shard, Self.lockShardCount),
            isDirectory: false
        )
        let lockFD = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard lockFD >= 0 else {
            return probe()
        }
        defer { Darwin.close(lockFD) }

        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ Self.lockWaitNanoseconds
        var observedContention = false
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EINTR else {
                return probe()
            }
            observedContention = observedContention
                || lockError == EWOULDBLOCK
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                // The owner may be suspended indefinitely. Run an independent,
                // already-bounded app-server probe instead of blocking resume.
                return probe()
            }
            Darwin.usleep(Self.lockRetryMicroseconds)
        }
        defer { _ = flock(lockFD, LOCK_UN) }

        if observedContention {
            let lockedLookup = lookup(at: cacheURL, key: key, now: Date())
            if lockedLookup.found {
                return lockedLookup.value
            }
        }

        try? FileManager.default.removeItem(at: cacheURL)
        let result = probe()
        prune(now: Date())
        write(result, key: key, to: cacheURL)
        return result
    }

    private func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
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
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func lookup(
        at url: URL,
        key: String,
        now: Date
    ) -> (found: Bool, value: Set<String>?) {
        let fileManager = FileManager.default
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
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func prune(now: Date) {
        let fileManager = FileManager.default
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
