public import Foundation

/// `cmux://screenshots`: the address of the Screenshots pane. The pane is a
/// browser tab record with this URL (like `cmux://agent-activity`), so the
/// workspace store persists and restores it with no new tab kind, and it
/// stays open across relaunches.
public nonisolated struct ScreenshotsPageAddress: Sendable {
    /// Makes the address value (the members are static; an instance carries nothing).
    public init() {}

    /// The address text.
    public static let string = "cmux://screenshots"
    /// The address (a literal a test parses; /dev/null stands in rather than a trap).
    public static let url: URL = URL(string: string) ?? URL(fileURLWithPath: "/dev/null")

    /// The page's tab title, localized ("Screenshots").
    public static var title: String { ScreenshotsStrings.title }

    /// `cmux://screenshots`, with or without a trailing slash, query or fragment.
    ///
    /// - Parameter url: any address.
    public static func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "cmux" else { return false }
        return url.host()?.lowercased() == "screenshots"
    }
}
