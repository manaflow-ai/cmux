import Foundation

public extension String {
    /// This string as one POSIX shell word.
    ///
    /// The string is returned unchanged when it is a bare word under
    /// ``isPOSIXShellBareWord(punctuation:)``'s default punctuation, and
    /// single-quoted otherwise, with each embedded `'` spliced as `'"'"'`.
    ///
    /// ```swift
    /// "alice@host-1".posixShellWord   // alice@host-1
    /// "a b".posixShellWord            // 'a b'
    /// "".posixShellWord               // ''
    /// ```
    var posixShellWord: String {
        if isPOSIXShellBareWord() { return self }
        return "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Whether this string is non-empty and contains only ASCII letters,
    /// digits and bytes from `punctuation`.
    ///
    /// Compares bytes rather than matching `^…$`: with NSString's ICU matching,
    /// `$` also matches before a final line terminator, so "name\n" would pass
    /// and end the command line early.
    ///
    /// - Parameter punctuation: ASCII punctuation allowed in a bare word. The
    ///   default, `_@%+=:,./-`, is the set ``posixShellWord`` leaves unquoted.
    /// - Returns: `true` when the string can appear unquoted in a shell command.
    func isPOSIXShellBareWord(punctuation: String = "_@%+=:,./-") -> Bool {
        let allowed = Array(punctuation.utf8)
        return !isEmpty && utf8.allSatisfy { byte in
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
