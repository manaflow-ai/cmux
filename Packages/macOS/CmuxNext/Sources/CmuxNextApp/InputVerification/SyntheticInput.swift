import AppKit

/// Input an agent posted into this app (`debug.mouse`), told apart from the
/// user's own input (stub).
@MainActor
enum SyntheticInput {
    static func register(_ events: [NSEvent]) {}

    /// Whether `event` is the user's own input (not one `register`ed).
    static func isUserInput(_ event: NSEvent) -> Bool { true }
}
