public import Foundation

/// One open-browser-tab candidate the omnibar can rank alongside history and
/// search suggestions.
///
/// `isKnownOpenTab` distinguishes a live tab the user can switch to (rendered as
/// a `switchToTab` suggestion) from a synthesized history-style row built from a
/// tab's URL/title (rendered as a `history` suggestion). The ranking engine reads
/// `url`/`title` for completion scoring and carries `tabId`/`panelId` so the
/// resulting `switchToTab` suggestion can focus the right surface.
public struct OmnibarOpenTabMatch: Equatable, Sendable {
    public let tabId: UUID
    public let panelId: UUID
    public let url: String
    public let title: String?
    public let isKnownOpenTab: Bool

    public init(tabId: UUID, panelId: UUID, url: String, title: String?, isKnownOpenTab: Bool = true) {
        self.tabId = tabId
        self.panelId = panelId
        self.url = url
        self.title = title
        self.isKnownOpenTab = isKnownOpenTab
    }
}
