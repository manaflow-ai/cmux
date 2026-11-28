public import Foundation

/// Derived layout values for the import wizard's source-profile selection step,
/// computed from the number of available source profiles.
public struct BrowserImportSourceProfilesPresentation: Equatable, Sendable {
    /// Height of the scrollable source-profile list, clamped to a usable range.
    public let scrollHeight: CGFloat
    /// Whether the multi-select help text is shown.
    public let showsHelpText: Bool

    /// Computes the source-profile-step layout from the profile count.
    ///
    /// - Parameter profileCount: Number of source profiles to display.
    public init(profileCount: Int) {
        let visibleRows = min(max(profileCount, 1), 5)
        let contentHeight = CGFloat(visibleRows * 26 + 14)
        scrollHeight = max(76, contentHeight)
        showsHelpText = profileCount > 1
    }
}
