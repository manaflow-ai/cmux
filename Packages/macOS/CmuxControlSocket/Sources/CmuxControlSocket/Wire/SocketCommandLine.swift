/// Framing-time rules for newline-delimited V1 control-socket command lines.
///
/// The V1 wire protocol terminates every request with a line feed, and the
/// server tokenizer additionally treats whitespace, quotes, and backslashes
/// as metacharacters. Any externally influenced value spliced into a command
/// line must therefore be encoded as exactly one token, and no composed line
/// may carry a raw line terminator. This type is the single choke point for
/// both rules: callers validate identifier-shaped values with
/// ``isSingleTokenArgument(_:)`` or ``agentHookPIDKeyArgument(statusKey:sessionId:)``
/// before composing a command, and every writer frames the finished line
/// through ``framedLine(for:)``, which refuses CR, LF, and NUL outright.
public enum SocketCommandLine {
    /// Maximum UTF-8 length accepted for a machine identifier embedded in a
    /// V1 command line as one unquoted token.
    public static let maximumSingleTokenArgumentLength = 256

    /// True when `text` contains a byte that would terminate or corrupt a
    /// newline-framed socket message (LF, CR, or NUL).
    public static func containsFramingControlCharacters(_ text: String) -> Bool {
        text.utf8.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0x00 }
    }

    /// True when `text` can be spliced into a V1 command line as exactly one
    /// unquoted token: 1...256 bytes drawn from `[A-Za-z0-9._:-]`. The
    /// allowlist excludes every framing byte and every tokenizer
    /// metacharacter (whitespace, quotes, backslash, `=`), so a conforming
    /// value can never change the shape of the surrounding command.
    public static func isSingleTokenArgument(_ text: String) -> Bool {
        let utf8 = text.utf8
        guard !utf8.isEmpty, utf8.count <= maximumSingleTokenArgumentLength else { return false }
        return utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            case 0x2E, 0x5F, 0x3A, 0x2D: // . _ : -
                return true
            default:
                return false
            }
        }
    }

    /// Composes the per-session agent PID key `<statusKey>.<sessionId>` as a
    /// single V1 argument. Returns nil when either part cannot be embedded as
    /// one token, so a hook-supplied session id can never smuggle framing or
    /// tokenizer metacharacters into `set_agent_pid`/`clear_agent_pid` lines.
    public static func agentHookPIDKeyArgument(statusKey: String, sessionId: String) -> String? {
        guard isSingleTokenArgument(statusKey), isSingleTokenArgument(sessionId) else {
            return nil
        }
        return "\(statusKey).\(sessionId)"
    }

    /// Returns `command` terminated for the newline-framed wire, or nil when
    /// the composed line itself still contains a framing control character
    /// and must not be written. Values that legitimately carry line breaks
    /// reach the wire only in their escaped, quoted form, which this guard
    /// accepts unchanged.
    public static func framedLine(for command: String) -> String? {
        guard !containsFramingControlCharacters(command) else { return nil }
        return command + "\n"
    }
}
