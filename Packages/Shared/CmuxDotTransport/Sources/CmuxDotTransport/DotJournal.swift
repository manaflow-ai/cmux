// JSONL journal, schema-compatible with the irx transport journal so the
// soak harness (scripts/irx-soak.py lineage) reads dot journals unchanged:
// {ts, mono_ms, component, event, a_<attr>: value...}

public import Foundation

public struct DotJournal: Sendable {
    private let write: @Sendable (String) -> Void
    private let startedAt: ContinuousClock.Instant

    public init(write: @escaping @Sendable (String) -> Void) {
        self.write = write
        self.startedAt = ContinuousClock.now
    }

    /// A journal appending JSONL lines to a file, creating it on first use.
    /// Also mirrors every line to os_log via the supplied logger closure.
    public static func file(url: URL, mirror: (@Sendable (String) -> Void)? = nil) -> DotJournal {
        let queue = DispatchQueue(label: "dev.cmux.dot.journal")
        return DotJournal { line in
            mirror?(line)
            queue.async {
                let data = Data((line + "\n").utf8)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    public static let discarding = DotJournal { _ in }

    public func record(
        component: String,
        event: String,
        attributes: [String: String] = [:]
    ) {
        var object: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "mono_ms": Int(startedAt.duration(to: .now).components.seconds * 1000)
                + Int(startedAt.duration(to: .now).components.attoseconds / 1_000_000_000_000_000),
            "component": component,
            "event": event,
        ]
        for (key, value) in attributes {
            object["a_\(key)"] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8)
        else { return }
        write(line)
    }
}
