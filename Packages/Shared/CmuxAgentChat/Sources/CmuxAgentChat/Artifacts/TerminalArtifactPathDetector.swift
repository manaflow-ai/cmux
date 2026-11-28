import Foundation

/// Detects path-like tokens in raw terminal text for artifact affordances.
///
/// Input may include VT escape sequences, such as those emitted by a terminal
/// screen export. Escape sequences are removed before path tokenization.
public struct TerminalArtifactPathDetector: Sendable {
    private enum EscapeScanState {
        case text
        case escape
        case escapeIntermediate
        case csi
        case stringControl(allowsBEL: Bool)
        case stringControlEscape(allowsBEL: Bool)
    }

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
        var state = EscapeScanState.text

        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            let value = scalar.value

            switch state {
            case .text:
                switch value {
                case 0x1B:
                    state = .escape
                case 0x9D:
                    // C1 OSC may end with BEL or ST.
                    state = .stringControl(allowsBEL: true)
                case 0x90, 0x98, 0x9E, 0x9F:
                    // C1 DCS, SOS, PM, and APC end only with ST.
                    state = .stringControl(allowsBEL: false)
                case 0x9B:
                    state = .csi
                case 0x9C:
                    // Strip a stray C1 ST just like a stray ESC \ terminator.
                    break
                default:
                    result.append(scalar)
                }

            case .escape:
                switch value {
                case 0x5B: // CSI: ESC [ parameters/intermediates final-byte
                    state = .csi
                case 0x5D:
                    // OSC: payload terminated by BEL or ST.
                    state = .stringControl(allowsBEL: true)
                case 0x50, 0x58, 0x5E, 0x5F:
                    // DCS, SOS, PM, and APC: payload terminated only by ST.
                    state = .stringControl(allowsBEL: false)
                case 0x20...0x2F:
                    state = .escapeIntermediate
                case 0x30...0x7E:
                    // Other two-character ESC sequences, including stray ST.
                    state = .text
                default:
                    // The scalar after ESC is not part of a recognized sequence.
                    // Keep it so ordinary printable text and whitespace survive.
                    result.append(scalar)
                    state = .text
                }

            case .escapeIntermediate:
                if (0x20...0x2F).contains(value) {
                    continue
                }
                state = .text
                if !(0x30...0x7E).contains(value) {
                    result.append(scalar)
                }

            case .csi:
                if (0x40...0x7E).contains(value) {
                    state = .text
                }

            case .stringControl(let allowsBEL):
                if value == 0x9C || (allowsBEL && value == 0x07) {
                    state = .text
                } else if value == 0x1B {
                    state = .stringControlEscape(allowsBEL: allowsBEL)
                }

            case .stringControlEscape(let allowsBEL):
                if value == 0x5C || value == 0x9C || (allowsBEL && value == 0x07) {
                    state = .text
                } else if value != 0x1B {
                    state = .stringControl(allowsBEL: allowsBEL)
                }
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
