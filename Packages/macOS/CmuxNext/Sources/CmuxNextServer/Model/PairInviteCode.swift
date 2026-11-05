public import Foundation

extension PairingCode {
    /// Invite code rules (the reverse of server pairing: a signed-in Mac shows the code and the new
    /// machine types it, `cmux pair ABCDE-12345`): 10 Crockford base32 symbols (50 bits), shown
    /// `XXXXX-XXXXX`, read like a server code (case insensitive, `O` as `0`, `I`/`L` as `1`,
    /// separators dropped). The length tells the two apart: an invite never passes
    /// ``PairingCode/isComplete(_:)`` and a server code never passes ``isComplete(_:)``.
    ///
    /// Longer than the 8-symbol server code because an invite is redeemed by `/v1/pair/begin`,
    /// which has no account to budget guesses against, only a per-IP limit.
    public nonisolated enum Invite {
        public static let length = 10

        /// `ABCDE12345` -> `ABCDE-12345`. Other lengths are returned unchanged.
        public static func display(_ code: String) -> String {
            guard code.count == length else { return code }
            return String(code.prefix(5)) + "-" + String(code.suffix(5))
        }

        /// Canonical symbols, the same reading as a server code (``PairingCode/normalize(_:)``).
        public static func normalize(_ input: String) -> String {
            PairingCode.normalize(input)
        }

        /// Whether `input` normalizes to a full valid invite code.
        public static func isComplete(_ input: String) -> Bool {
            let code = normalize(input)
            return code.count == length && code.allSatisfy { alphabet.contains($0) }
        }

        /// The one line the new machine runs: `cmux pair ABCDE-12345`.
        public static func line(_ code: String) -> String {
            "cmux pair \(display(normalize(code)))"
        }

        /// The same for a Mac or Linux machine without cmux: the install line "Set up a new device"
        /// shows (``AddDevicePlatform/setupLine``), then the invite.
        public static func installLine(_ code: String) -> String {
            "curl -fsSL https://cmux.com/tui/install-static.sh | sh && ~/.cmux/bin/\(line(code))"
        }

        /// The QR payload: a universal link with the invite in the query (`i=`, never the server
        /// code's `c=`), so a phone or a laptop camera can carry it to the new machine.
        public static func payload(_ code: String) -> String {
            "https://cmux.com/pair?i=\(normalize(code))"
        }
    }
}
