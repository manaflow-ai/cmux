import Foundation

/// Pure policy normalizing and validating the magic-link sign-in code as the user types.
public struct SignInCodeInputPolicy {
    private init() {}

    /// The maximum number of characters a sign-in code may contain.
    public static let maximumCodeLength = 6

    /// Decides the action to take for a newly entered code value.
    /// - Parameter value: The raw field value after the change.
    /// - Returns: `.assign` to replace with the normalized value, `.verify` when complete, or `.none`.
    public static func action(for value: String) -> SignInCodeInputChangeAction {
        let normalized = normalizedCode(value)
        guard normalized == value else {
            return .assign(normalized)
        }
        return shouldVerifyAfterChange(normalized) ? .verify : .none
    }

    /// Normalizes a code by trimming whitespace and clamping to ``maximumCodeLength``.
    /// - Parameter value: The raw code string.
    /// - Returns: The normalized code.
    public static func normalizedCode(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumCodeLength))
    }

    /// Whether a normalized code is complete and should trigger verification.
    /// - Parameter normalizedCode: A code already passed through ``normalizedCode(_:)``.
    /// - Returns: `true` when the code has exactly ``maximumCodeLength`` characters.
    public static func shouldVerifyAfterChange(_ normalizedCode: String) -> Bool {
        normalizedCode.count == maximumCodeLength
    }
}
