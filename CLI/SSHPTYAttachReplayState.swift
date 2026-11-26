import Foundation

/// Persists the last fully delivered PTY snapshot for one attach lifecycle.
///
/// The remote daemon's replay is a prefix of the current bounded scrollback
/// while the session remains healthy. Remembering the delivered length and a
/// content fingerprint lets a reattach hide only bytes already rendered by
/// this lifecycle; bounded-scrollback rollover safely falls back to forwarding
/// the replacement snapshot. The lifecycle identifier keeps a fresh attach
/// from inheriting offsets from an older shell generation.
struct SSHPTYAttachReplayState: Sendable {
    private static let filePrefix = "cmux-ssh-pty-replay"

    private let sessionID: String
    private let lifecycleID: String

    init(sessionID: String, lifecycleID: String) {
        self.sessionID = sessionID
        self.lifecycleID = lifecycleID
    }

    struct Snapshot: Sendable {
        let replayBytes: Int
        let fingerprint: UInt64?
    }

    func loadSnapshot() -> Snapshot? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let fields = contents.split(separator: "\n", omittingEmptySubsequences: true)
        guard fields.count >= 2,
              let value = Int(fields[1]),
              value >= 0 else {
            return nil
        }
        if fields[0] == "v2",
           fields.count == 3,
           let fingerprint = UInt64(fields[2], radix: 16) {
            return Snapshot(replayBytes: value, fingerprint: fingerprint)
        }
        guard fields[0] == "v1" else { return nil }
        return Snapshot(replayBytes: value, fingerprint: nil)
    }

    func storeSnapshot(replayBytes: Int, fingerprint: UInt64) {
        guard replayBytes >= 0 else { return }
        let contents = "v2\n\(replayBytes)\n\(String(fingerprint, radix: 16))\n"
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
