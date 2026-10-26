import CmuxNextHibernation
public import Foundation

/// Files dropped on a page that the page itself cannot open: WebKit hides the
/// paths of Finder drags from page script, so a page that opens dropped
/// folders (the diff viewer's empty state, diff-host.md) has its host take the
/// drop. `accepts` decides per URL (it runs once when a drag enters the page;
/// the answer holds until the drag ends); a refused drag goes to the page as usual.
/// `open` reads the drop and returns once it has opened or refused it: until then
/// the page keeps its `fileDrop` keep reason (``take(_:keep:)``).
@MainActor
public struct PageFileDrop {
    public let accepts: @MainActor (URL) -> Bool
    public let open: @MainActor (URL) async -> Void

    public init(accepts: @escaping @MainActor (URL) -> Bool, open: @escaping @MainActor (URL) async -> Void) {
        self.accepts = accepts
        self.open = open
    }

    /// The host took a drop of `url` (WebKit's `performDragOperation`, the Chromium page's hand-over):
    /// `keep` holds the page's `fileDrop` reason from the drop until ``open`` returns, so a hidden
    /// page is not frozen or discarded while its drop is still read.
    @discardableResult
    func take(_ url: URL, keep: PageKeepReasons?) -> Task<Void, Never> {
        keep?.begin(.fileDrop)
        let open = open
        // task-owner: one host read of a dropped file; ends when its owner opened or refused it
        return Task { @MainActor in
            await open(url)
            keep?.end(.fileDrop)
        }
    }
}
