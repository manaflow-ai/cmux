import Foundation

/// Persists the last fully delivered PTY snapshot for one attach lifecycle.
///
/// The remote daemon's replay is a prefix of the current bounded scrollback
/// while the session remains healthy. Remembering that prefix length lets a
/// reattach hide only bytes already rendered by this lifecycle; output appended
/// while detached remains visible. The lifecycle identifier keeps a fresh
/// attach from inheriting offsets from an older shell generation.
struct SSHPTYAttachReplayState: Sendable {
    private static let filePrefix = "cmux-ssh-pty-replay"

    private let sessionID: String
    private let lifecycleID: String

    init(sessionID: String, lifecycleID: String) {
        self.sessionID = sessionID
        self.lifecycleID = lifecycleID
    }

    func loadReplayBytes() -> Int? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let fields = contents.split(separator: "\n", omittingEmptySubsequences: true)
        guard fields.count == 2,
              fields[0] == "v1",
              let value = Int(fields[1]),
              value >= 0 else {
            return nil
        }
        return value
    }

    func storeReplayBytes(_ value: Int) {
        guard value >= 0 else { return }
        let contents = "v1\n\(value)\n"
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private var fileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.filePrefix)-\(stableKey)", isDirectory: false)
    }

    private var stableKey: String {
        var hash: UInt64 = 14695981039346656037
        for byte in (sessionID + "\u{0}" + lifecycleID).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}
