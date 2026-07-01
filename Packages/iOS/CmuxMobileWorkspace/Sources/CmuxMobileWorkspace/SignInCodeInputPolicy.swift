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

    /// Normalizes a code by keeping ASCII letters/digits, uppercasing letters,
    /// and clamping to ``maximumCodeLength``.
    /// - Parameter value: The raw code string.
    /// - Returns: The normalized code.
    public static func normalizedCode(_ value: String) -> String {
        var normalized = ""
        normalized.reserveCapacity(maximumCodeLength)

        for scalar in value.unicodeScalars {
            guard normalized.count < maximumCodeLength else { break }
            switch scalar.value {
            case 48...57:
                normalized.unicodeScalars.append(scalar)
            case 65...90:
                normalized.unicodeScalars.append(scalar)
            case 97...122:
                guard let uppercase = UnicodeScalar(scalar.value - 32) else { continue }
                normalized.unicodeScalars.append(uppercase)
            default:
                continue
            }
        }

        return normalized
    }

    /// Whether a normalized code is complete and should trigger verification.
    /// - Parameter normalizedCode: A code already passed through ``normalizedCode(_:)``.
    /// - Returns: `true` when the code has exactly ``maximumCodeLength`` characters.
    public static func shouldVerifyAfterChange(_ normalizedCode: String) -> Bool {
        normalizedCode.count == maximumCodeLength
    }
}
