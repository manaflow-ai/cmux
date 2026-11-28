public import Foundation

/// Files dropped on a page that the page itself cannot open: WebKit hides the
/// paths of Finder drags from page script, so a page that opens dropped
/// folders (the diff viewer's empty state, diff-host.md) has its host take the
/// drop. `accepts` decides per URL (it runs on every drag move, so it must be
/// cheap); a refused drag goes to the page as usual.
@MainActor
public struct PageFileDrop {
    public let accepts: @MainActor (URL) -> Bool
    public let open: @MainActor (URL) -> Void

    public init(accepts: @escaping @MainActor (URL) -> Bool, open: @escaping @MainActor (URL) -> Void) {
        self.accepts = accepts
        self.open = open
    }
}
