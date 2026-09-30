import Foundation

/// Closing an incognito window, or quitting with one open, ends its
/// terminals. Stub.
enum IncognitoCloseConfirmation {
    static func prompt(programs: [String], quitting: Bool) -> DestructiveConfirmation.Prompt? { nil }
}
