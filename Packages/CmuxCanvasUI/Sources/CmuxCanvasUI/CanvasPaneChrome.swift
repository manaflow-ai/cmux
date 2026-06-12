public import Foundation

/// Value snapshot of a pane's chrome strip. Localized text crosses this seam
/// pre-resolved so the package owns no string catalogs.
public struct CanvasPaneChrome: Equatable, Sendable {
    public var title: String
    public var iconSystemName: String?
    public var isFocused: Bool
    /// Localized label for the close button (help tag + accessibility).
    public var closeActionLabel: String

    public init(
        title: String,
        iconSystemName: String?,
        isFocused: Bool,
        closeActionLabel: String
    ) {
        self.title = title
        self.iconSystemName = iconSystemName
        self.isFocused = isFocused
        self.closeActionLabel = closeActionLabel
    }
}
