import Foundation

/// Surface-resume command canonicalization, expressed as operations on the
/// `String` they consume rather than a static utility namespace. These mirror
/// the legacy `SurfaceResumeCommandCanonicalizer` helpers byte-for-byte; only
/// the receiver changed from an explicit argument to `self`.
extension String {
    /// Splits this shell command into argv tokens, honoring single and double
    /// quotes and backslash escapes (double-quoted backslash escapes the next
    /// scalar; an unquoted trailing backslash escapes the next scalar). Returns
    /// `nil` when a quote is left open or the command produces no tokens.
    public func surfaceResumeCommandTokens() -> [String]? {
        let scalars = Array(unicodeScalars)
        var tokens: [String] = []
        var token = String.UnicodeScalarView()
        var index = 0
        var quote: UnicodeScalar?

        func flushToken() {
            guard !token.isEmpty else { return }
            tokens.append(String(token))
            token.removeAll(keepingCapacity: true)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if let activeQuote = quote {
                if scalar == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", scalar == "\\", index + 1 < scalars.count {
                    index += 1
                    token.append(scalars[index])
                } else {
                    token.append(scalar)
                }
            } else if scalar == "'" || scalar == "\"" {
                quote = scalar
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushToken()
            } else if scalar == "\\", index + 1 < scalars.count {
                index += 1
                token.append(scalars[index])
            } else {
                token.append(scalar)
            }
            index += 1
        }

        guard quote == nil else { return nil }
        flushToken()
        return tokens.isEmpty ? nil : tokens
    }

    /// This value normalized as a working directory: trimmed of surrounding
    /// whitespace, tilde-expanded, and standardized. `nil` when empty after
    /// trimming.
    public var surfaceResumeNormalizedCWD: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// This value shell-quoted for inclusion in a command line. Returns `''`
    /// when empty, the value unchanged when every scalar is in the shell-safe
    /// allowlist, and a single-quoted form (with embedded single quotes escaped)
    /// otherwise.
    public var surfaceResumeShellQuoted: String {
        guard !isEmpty else { return "''" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=./:@%")
        if unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
