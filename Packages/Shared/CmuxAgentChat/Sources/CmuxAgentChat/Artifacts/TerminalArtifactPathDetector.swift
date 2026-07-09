import Foundation

/// Detects path-like tokens in terminal text for artifact affordances.
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

    /// Returns path-like tokens in display order.
    public func tokens(in text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let candidate = Self.trimmedCandidate(String(raw))
            guard Self.isPathLike(candidate) else { return nil }
            return Token(path: candidate)
        }
    }

    private static func trimmedCandidate(_ token: String) -> String {
        var result = token
        let leading = CharacterSet(charactersIn: "\"'`([{<")
        let trailing = CharacterSet(charactersIn: "\"'`)]}>,;:!?")
        result = result.trimmingCharacters(in: leading)
        while let scalar = result.unicodeScalars.last,
              trailing.contains(scalar) || (scalar.value == 46 && !result.hasSuffix("..")) {
            result.removeLast()
        }
        if result.hasPrefix("file://"),
           let url = URL(string: result),
           url.isFileURL {
            result = url.path
        }
        return result
    }

    private static func isPathLike(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if candidate.hasPrefix("http://") || candidate.hasPrefix("https://") {
            return false
        }
        if candidate.hasPrefix("/") || candidate.hasPrefix("./") || candidate.hasPrefix("../") {
            return true
        }
        return candidate.contains("/") && !candidate.contains("://")
    }
}
