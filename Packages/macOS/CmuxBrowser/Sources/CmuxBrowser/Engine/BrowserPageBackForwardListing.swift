public import Foundation

/// One entry of a page's back/forward list.
public struct BrowserBackForwardEntry: Equatable, Sendable {
    /// The entry's address.
    public var url: URL?
    /// The page title, `nil` when the page had none.
    public var title: String?
    /// Steps from the current entry: negative is back, positive forward.
    public var offset: Int

    public init(url: URL?, title: String?, offset: Int) {
        self.url = url
        self.title = title
        self.offset = offset
    }
}

/// A page's back and forward entries, each nearest first.
public struct BrowserBackForwardList: Equatable, Sendable {
    /// Entries behind the current one, nearest first.
    public var back: [BrowserBackForwardEntry]
    /// Entries ahead of the current one, nearest first.
    public var forward: [BrowserBackForwardEntry]

    public init(back: [BrowserBackForwardEntry], forward: [BrowserBackForwardEntry]) {
        self.back = back
        self.forward = forward
    }
}

/// A page whose engine lists its back/forward entries, for the Back and
/// Forward buttons' history menus (right-click or long-press).
@MainActor
public protocol BrowserPageBackForwardListing: AnyObject {
    /// The page's entries, or `nil` when the engine cannot list them now.
    func backForwardList() -> BrowserBackForwardList?
    /// Navigates `offset` entries from the current one (negative is back).
    /// - Returns: `false` when the engine refused.
    @discardableResult
    func goToBackForwardEntry(offset: Int) -> Bool
}
