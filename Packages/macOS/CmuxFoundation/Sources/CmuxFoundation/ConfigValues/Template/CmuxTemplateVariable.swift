import Foundation

/// A named `{{variable}}` placeholder and its optional inline default value.
public struct CmuxTemplateVariable: Equatable, Sendable {
    /// The placeholder name.
    public let name: String

    /// The value after `=` in `{{name=default}}`, or `nil` when none was declared.
    public let defaultValue: String?

    /// Creates a parsed template variable.
    ///
    /// - Parameters:
    ///   - name: The placeholder name.
    ///   - defaultValue: The optional inline default value.
    public init(name: String, defaultValue: String?) {
        self.name = name
        self.defaultValue = defaultValue
    }

    /// Returns whether a name is valid in a cmux template placeholder.
    ///
    /// Names start with a letter or `_` and continue with letters, digits, `_`,
    /// or `-`, matching the custom-command variable grammar from #6898.
    ///
    /// - Parameter name: The candidate placeholder name.
    /// - Returns: `true` when the name follows the cmux template grammar.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else {
            return false
        }
        return name.unicodeScalars.allSatisfy { trailingNameCharacters.contains($0) }
    }

    private static let trailingNameCharacters = CharacterSet.letters
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: "_-"))
}
