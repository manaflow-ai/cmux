internal import Foundation

/// The sidebar progress state for the `sidebar_state` listing.
public struct ControlSidebarProgressInfo: Sendable, Equatable {
    /// The progress value (0.0 to 1.0).
    public let value: Double
    /// The optional progress label.
    public let label: String?

    /// Creates the info.
    ///
    /// - Parameters:
    ///   - value: The progress value.
    ///   - label: The optional progress label.
    public init(value: Double, label: String?) {
        self.value = value
        self.label = label
    }
}
