import Foundation

/// A short, 1–2 character label derived from a project name, used as the
/// sidebar avatar when no app icon is available.
public struct ProjectMonogram: Sendable, Equatable {
    /// The uppercased monogram (always 1–2 characters, or `"?"` when empty).
    public let value: String

    /// Derives a monogram from `projectName`.
    ///
    /// Splits on `-`, `_`, `.`, and whitespace. With two or more tokens the
    /// monogram is the first letter of the first two tokens; with one token it
    /// is that token's first two letters.
    public init(projectName: String) {
        let separators = CharacterSet(charactersIn: "-_. ").union(.whitespaces)
        let tokens = projectName
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        if tokens.count >= 2 {
            let first = tokens[0].prefix(1)
            let second = tokens[1].prefix(1)
            value = (first + second).uppercased()
        } else if let only = tokens.first {
            value = String(only.prefix(2)).uppercased()
        } else {
            value = "?"
        }
    }
}
