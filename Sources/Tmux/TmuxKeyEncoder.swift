import Foundation

/// Encodes raw byte data into tmux `send-keys` commands.
///
/// Per the iTerm2 tmux integration spec (SS8), bytes are classified as:
/// - **Literal**: `[a-zA-Z0-9+/):,_]` → `send-keys -lt %<pane> <chars>`
/// - **Non-literal**: everything else → `send-keys -t %<pane> 0xNN`
///
/// Batch limits prevent overly long commands:
/// - Max 1000 literal characters per command
/// - Max 125 hex values per command
enum TmuxKeyEncoder {

    /// Maximum literal characters per `send-keys -l` command.
    static let maxLiteralBatch = 1000

    /// Maximum hex values per `send-keys` command.
    static let maxHexBatch = 125

    /// Characters that can be sent as literal text with `send-keys -l`.
    private static let literalCharacterSet: Set<UInt8> = {
        var set = Set<UInt8>()
        // a-z
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(c) }
        // A-Z
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(c) }
        // 0-9
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(c) }
        // Special literal characters: +/):,_
        for ch: UInt8 in [0x2B, 0x2F, 0x29, 0x3A, 0x2C, 0x5F] { set.insert(ch) }
        // Space is also literal
        set.insert(0x20)
        return set
    }()

    /// Encode raw bytes into one or more tmux `send-keys` commands for a pane.
    ///
    /// Returns an array of command strings, each terminated with a newline.
    static func encode(_ data: Data, forPane paneId: Int) -> [String] {
        guard !data.isEmpty else { return [] }

        var commands: [String] = []
        var currentLiteralBatch = ""
        var currentHexBatch: [String] = []

        func flushLiteral() {
            guard !currentLiteralBatch.isEmpty else { return }
            commands.append("send-keys -lt %\(paneId) \(currentLiteralBatch)\n")
            currentLiteralBatch = ""
        }

        func flushHex() {
            guard !currentHexBatch.isEmpty else { return }
            let hexArgs = currentHexBatch.joined(separator: " ")
            commands.append("send-keys -t %\(paneId) \(hexArgs)\n")
            currentHexBatch = []
        }

        for byte in data {
            if literalCharacterSet.contains(byte) {
                // Flush any pending hex batch before switching to literal
                flushHex()

                currentLiteralBatch.append(Character(UnicodeScalar(byte)))
                if currentLiteralBatch.count >= maxLiteralBatch {
                    flushLiteral()
                }
            } else {
                // Flush any pending literal batch before switching to hex
                flushLiteral()

                currentHexBatch.append(String(format: "0x%02X", byte))
                if currentHexBatch.count >= maxHexBatch {
                    flushHex()
                }
            }
        }

        // Flush remaining
        flushLiteral()
        flushHex()

        return commands
    }
}
