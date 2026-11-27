import Foundation

/// The action the sign-in code field should take after its text changes.
public enum SignInCodeInputChangeAction: Equatable, Sendable {
    /// Replace the field's value with the normalized string.
    case assign(String)
    /// The code is complete; trigger verification.
    case verify
    /// No action is required.
    case none
}
