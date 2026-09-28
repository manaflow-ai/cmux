/// Renders a value as one POSIX shell word.
public enum POSIXShellWord {
    /// ASCII punctuation that may appear in a bare (unquoted) word.
    public static let bareWordPunctuation = "_@%+=:,./-"

    /// Returns `value` unchanged when every byte is safe in a bare word,
    /// otherwise single-quotes it.
    public static func quoted(_ value: String) -> String {
        if isBare(value) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Whether `value` is non-empty and contains only ASCII letters, digits
    /// and bytes from `punctuation`.
    ///
    /// Compares bytes rather than matching `^…$`: with NSString's ICU matching,
    /// `$` also matches before a final line terminator, so "name\n" would pass
    /// and end the command line early.
    public static func isBare(_ value: String, punctuation: String = bareWordPunctuation) -> Bool {
        let allowed = Array(punctuation.utf8)
        return !value.isEmpty && value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"):
                return true
            default:
                return allowed.contains(byte)
            }
        }
    }
}

/// Checks on an ssh destination before it becomes an argv element.
public enum SSHDestinationArgument {
    /// Whether ssh would read `destination` as an option rather than a host.
    ///
    /// Argv builders that cannot put `--` ahead of the destination (the
    /// interactive ssh command, which the user may extend) reject these
    /// values at input instead.
    public static func isOptionLike(_ destination: String) -> Bool {
        destination.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
    }
}

/// `-o` overrides for background ssh runs that only execute a helper command.
///
/// OpenSSH keeps the first value it reads for most options, so callers place
/// these before any configured options.
public enum SSHBackgroundForwardingOptions {
    /// Turns off agent and X11 forwarding. Use on runs that set up their own
    /// `-L` or `-R` forward, which `ClearAllForwardings` would also drop.
    public static let agentAndX11Off = [
        "-o", "ForwardAgent=no",
        "-o", "ForwardX11=no",
    ]

    /// Turns off agent, X11 and every configured port forward.
    public static let allOff = agentAndX11Off + [
        "-o", "ClearAllForwardings=yes",
    ]
}
