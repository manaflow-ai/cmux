import Foundation

/// Detects path-like tokens in raw terminal text for artifact affordances.
///
/// Input may include VT escape sequences, such as those emitted by a terminal
/// screen export. Escape sequences are removed before path tokenization.
public struct TerminalArtifactPathDetector: Sendable {
    /// A detected terminal path token.
    public struct Token: Sendable, Equatable {
        /// Token text after shell-punctuation trimming.
        public let path: String

        /// Creates a detected token.
        public init(path: String) {
            self.path = path
        }
    }

    /// Creates a detector.
    public init() {}

    /// Returns unique path-like tokens in display order.
    public func paths(in text: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for token in tokens(in: text) where !seen.contains(token.path) {
            seen.insert(token.path)
            result.append(token.path)
        }
        return result
    }

    /// Returns path-like tokens in display order from plain or VT-escaped text.
    public func tokens(in text: String) -> [Token] {
        Self.strippingTerminalEscapeSequences(text)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { raw in
                let candidate = Self.trimmedCandidate(String(raw))
                guard Self.isPathLike(candidate) else { return nil }
                return Token(path: candidate)
            }
    }

    /// Removes VT escape sequences with one bounded scalar pass so raw screen
    /// exports can be tokenized without escape terminators contaminating paths.
    private static func strippingTerminalEscapeSequences(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var result = String.UnicodeScalarView()
        var index = scalars.startIndex

        while index < scalars.endIndex {
            guard scalars[index].value == 0x1B else {
                result.append(scalars[index])
                index = scalars.index(after: index)
                continue
            }

            index = scalars.index(after: index)
            guard index < scalars.endIndex else { break }

            switch scalars[index].value {
            case 0x5B: // CSI: ESC [ parameters/intermediates final-byte
                index = scalars.index(after: index)
                while index < scalars.endIndex {
                    let value = scalars[index].value
                    index = scalars.index(after: index)
                    if (0x40...0x7E).contains(value) {
                        break
                    }
                }

            case 0x5D: // OSC: ESC ] payload BEL-or-ST
                index = scalars.index(after: index)
                while index < scalars.endIndex {
                    if scalars[index].value == 0x07 {
                        index = scalars.index(after: index)
                        break
                    }
                    if scalars[index].value == 0x1B {
                        let next = scalars.index(after: index)
                        if next < scalars.endIndex, scalars[next].value == 0x5C {
                            index = scalars.index(after: next)
                            break
                        }
                    }
                    index = scalars.index(after: index)
                }

            case 0x20...0x2F:
                // ESC sequences may contain intermediate bytes, for example
                // the charset selection ESC ( B, followed by one final byte.
                repeat {
                    index = scalars.index(after: index)
                } while index < scalars.endIndex
                    && (0x20...0x2F).contains(scalars[index].value)
                if index < scalars.endIndex,
                   (0x30...0x7E).contains(scalars[index].value) {
                    index = scalars.index(after: index)
                }

            case 0x30...0x7E:
                // Other two-character ESC sequences, including stray ST.
                index = scalars.index(after: index)

            default:
                // The scalar after ESC is not part of a recognized sequence.
                // Keep it so ordinary printable text and whitespace survive.
                continue
            }
        }

        return String(result)
    }

    private static func trimmedCandidate(_ token: String) -> String {
        var result = token
        let leading = CharacterSet(charactersIn: "\"'`([{<")
        let trailing = CharacterSet(charactersIn: "\"'`)]}>,;:!?")
        result = result.trimmingCharacters(in: leading)
        if let destination = result.range(of: "]("),
           destination.upperBound < result.endIndex {
            let linked = String(result[destination.upperBound...])
            if linked.hasPrefix("/") || linked.hasPrefix("~/") || linked.hasPrefix("file://") {
                result = linked
            }
        }
        while let scalar = result.unicodeScalars.last,
              trailing.contains(scalar) || (scalar.value == 46 && !result.hasSuffix("..")) {
            result.removeLast()
        }
        if result.hasPrefix("file://"),
           let url = URL(string: result),
           url.isFileURL {
            result = url.path
        }
        return Self.strippingSourceLocationSuffix(result)
    }

    /// Strips the grep/compiler `:line(:column)?(:match)?` suffix with one
    /// bounded scalar pass. This runs for every terminal token, including
    /// very large tool-output tokens, so regex backtracking is inappropriate.
    private static func strippingSourceLocationSuffix(_ candidate: String) -> String {
        let scalars = candidate.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            guard scalars[index].value == 58 else {
                index = scalars.index(after: index)
                continue
            }
            var cursor = scalars.index(after: index)
            let digitStart = cursor
            while cursor < scalars.endIndex,
                  (48...57).contains(scalars[cursor].value) {
                cursor = scalars.index(after: cursor)
            }
            if cursor > digitStart,
               cursor == scalars.endIndex || scalars[cursor].value == 58 {
                return String(candidate[..<index])
            }
            index = scalars.index(after: index)
        }
        return candidate
    }

    private static func isPathLike(_ candidate: String) -> Bool {
        guard !candidate.isEmpty,
              Self.hasEnoughPathComponents(candidate),
              !candidate.unicodeScalars.contains(where: Self.forbiddenTokenCharacters.contains),
              !candidate.contains("("),
              !candidate.contains(")") else { return false }
        if candidate.hasPrefix("http://") || candidate.hasPrefix("https://") {
            return false
        }
        if candidate.hasPrefix("/") || candidate.hasPrefix("./") || candidate.hasPrefix("../") {
            return true
        }
        return candidate.contains("/") && !candidate.contains("://")
    }

    private static let forbiddenTokenCharacters = CharacterSet(charactersIn: "<>\"'\\`")

    private static func hasEnoughPathComponents(_ candidate: String) -> Bool {
        // The component floor exists to reject the bare-root tokens ("/",
        // "/.") that shell output produces constantly; a relative token like
        // "./notes.md" is already a deliberate path shape, so only absolute
        // candidates are held to it.
        guard candidate.hasPrefix("/") else { return true }
        let standardized = (candidate as NSString).standardizingPath
        return (standardized as NSString).pathComponents.count >= 2
    }
}
