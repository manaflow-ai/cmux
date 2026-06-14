internal import Foundation

/// The first display-ordered pull request for the `sidebar_state` listing.
public struct ControlSidebarPullRequestInfo: Sendable, Equatable {
    /// The PR number.
    public let number: Int
    /// The PR status raw value (`open`/`merged`/`closed`).
    public let statusRawValue: String
    /// The PR URL absolute string.
    public let urlAbsoluteString: String
    /// The PR label.
    public let label: String

    /// Creates the info.
    ///
    /// - Parameters:
    ///   - number: The PR number.
    ///   - statusRawValue: The PR status raw value.
    ///   - urlAbsoluteString: The PR URL absolute string.
    ///   - label: The PR label.
    public init(number: Int, statusRawValue: String, urlAbsoluteString: String, label: String) {
        self.number = number
        self.statusRawValue = statusRawValue
        self.urlAbsoluteString = urlAbsoluteString
        self.label = label
    }
}
