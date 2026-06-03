public import Foundation

extension Array where Element == String {
    /// The pins with surrounding whitespace trimmed, empties removed, and duplicates dropped.
    ///
    /// Used to canonicalize direct-TLS certificate pins on a ``TerminalHost`` so the same
    /// pin set always compares equal regardless of input formatting or ordering noise.
    public var normalizedTerminalPins: [String] {
        var seen = Set<String>()
        return compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}
