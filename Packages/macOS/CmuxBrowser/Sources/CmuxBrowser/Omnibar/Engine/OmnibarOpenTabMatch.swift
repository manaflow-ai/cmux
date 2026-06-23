public import Foundation

/// One open-browser-tab match fed into the omnibar suggestion ranking: the
/// workspace/panel identity plus the tab's URL and title.
///
/// `isKnownOpenTab` distinguishes a live open tab (rendered as a "switch to
/// tab" row) from a tab-derived candidate surfaced as a history row.
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
