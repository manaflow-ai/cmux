public import Foundation

/// The outcome of moving every main window onto one display, returned by
/// ``ControlCommandContext/controlMoveAllWindows(toDisplayMatching:)``.
public struct ControlMoveAllWindowsResult: Sendable, Equatable {
    /// The resolved display's localized name.
    public let display: String
    /// The identifiers of the windows that were moved.
    public let windowIDs: [UUID]

    /// Creates a move-all result.
    ///
    /// - Parameters:
    ///   - display: The resolved display name.
    ///   - windowIDs: The moved window identifiers.
    public init(display: String, windowIDs: [UUID]) {
        self.display = display
        self.windowIDs = windowIDs
    }
}
