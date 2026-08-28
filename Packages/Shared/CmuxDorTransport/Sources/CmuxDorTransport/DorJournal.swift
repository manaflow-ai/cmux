// JSONL journal, schema-compatible with the irx/dot transport journals so the
// engaged-soak analyzer reads dor journals unchanged:
// {ts, mono_ms, component, event, a_<attr>: value...}

public import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct DorJournal: Sendable {
    private let write: @Sendable (String) -> Void
    private let startedAt: ContinuousClock.Instant

    public init(write: @escaping @Sendable (String) -> Void) {
        self.write = write
        self.startedAt = ContinuousClock.now
    }

    /// A journal appending JSONL lines to a file, creating it on first use,
    /// mirroring every line to the supplied closure (os_log in the apps).
    public static func file(url: URL, mirror: (@Sendable (String) -> Void)? = nil) -> DorJournal {
        let queue = DispatchQueue(label: "dev.cmux.dor.journal")
        return DorJournal { line in
            mirror?(line)
            queue.async {
                let data = Data((line + "\n").utf8)
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
#if canImport(Darwin)
                // O_NOFOLLOW prevents a local process from replacing the
                // journal with a symlink between launches. O_APPEND keeps
                // records atomic and 0600 limits disclosure to this user.
                let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW
                let descriptor = Darwin.open(url.path, flags, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { return }
                _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try? handle.write(contentsOf: data)
                try? handle.close()
#else
                // This package targets Apple platforms. Keep a functional
                // fallback for source-only tooling on other hosts.
                try? data.write(to: url, options: .atomic)
#endif
            }
        }
    }

    public static let discarding = DorJournal { _ in }

    public func record(
        component: String,
        event: String,
        attributes: [String: String] = [:]
    ) {
        let elapsed = startedAt.duration(to: .now)
        var object: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "mono_ms": Int(elapsed.components.seconds) * 1000
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000),
            "component": component,
            "event": event,
        ]
        for (key, value) in attributes {
            object["a_\(key)"] = DorSafety.journalValue(key: key, value: value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8)
        else { return }
        write(line)
    }
}
