public import AppKit
import CmuxNextDesign
import CmuxNextPages
public import CmuxNextSettings
import Observation

/// The "Bookmark Added" / "Edit Bookmark" bubble from the omnibar star: the React page
/// `webviews/src/pages/bookmark-edit` (Name, Folder, Remove, Done, More…) in a popup of the shared
/// native host (``NativePopupHost``) under the star. This type only hosts it: it places the card,
/// pushes the bookmark and the daemon's folder choices to the page, and passes the page's commands
/// to its owner. Return or Done saves; Escape or a click outside closes and also saves.
///
/// The page sends `edit {title, folder}` on each change, so a dismiss saves what it shows, and
/// `done`, `remove` and `more`. It reports the height of each state it drew (`size`); the bubble
/// opens at that size, so it never grows after it appeared.
@MainActor
public final class BookmarkEditBubble {
    public struct Result: Sendable, Equatable {
        public var title: String
        public var folder: String

        public init(title: String, folder: String) {
            self.title = title
            self.folder = folder
        }
    }

    /// The bubble's width in points (its old SwiftUI form's).
    static var width: CGFloat { (Metrics.paletteWidth * 0.5).rounded() }

    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.bookmarks.edit"))
    private let isNew: Bool
    private var draft: Result
    private let folders: JSONValue
    private var finished = false
    private let onSave: (Result) -> Void
    private let onRemove: () -> Void
    private let onMore: () -> Void
    /// The page's title now (observable): a new bookmark made before the page had a title takes
    /// it when it arrives, unless the name was edited.
    private let pageTitle: (() -> String?)?
    /// The name the bubble filled in last (from the page); a different name is the person's.
    private var filledTitle: String
    private var content: BrowserChromeWebHost?
    private weak var anchor: NSView?
    /// Counts the states pushed; a size report names the one it measured.
    private var revision = 0
    private var presentsOnSize = false
    /// The open bubble, so a second press on the star closes it.
    public private(set) static var current: BookmarkEditBubble?

    /// `folders`: the daemon's folder choices (`bookmarks.folders`, `[{id, title, depth}]`).
    public init(isNew: Bool, title: String, folder: String, folders: JSONValue, pageTitle: (() -> String?)? = nil,
                onSave: @escaping (Result) -> Void, onRemove: @escaping () -> Void, onMore: @escaping () -> Void) {
        self.isNew = isNew
        draft = Result(title: title, folder: folder)
        self.folders = folders
        self.pageTitle = isNew ? pageTitle : nil
        filledTitle = title
        self.onSave = onSave
        self.onRemove = onRemove
        self.onMore = onMore
        // A dismiss (click outside, Escape, the app or window going away) keeps the edits.
        popup.onDismiss = { [weak self] in self?.closed() }
    }

    /// Opens under `anchor` once the page drew its first state.
    public func show(relativeTo anchor: NSView) {
        BookmarkEditBubble.current?.close()
        guard let window = anchor.window, let content = content ?? makePage() else { return }
        self.anchor = anchor
        popup.panel.adoptThemeScope(of: anchor)
        // A press on the star toggles the bubble: the star closes it, not the click monitor.
        popup.keepsOpen = { [weak anchor] event in
            guard let anchor, event.window === anchor.window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        BookmarkEditBubble.current = self
        presentsOnSize = true
        // A click outside, a deactivation or a window move before the page's size arrives drops the open.
        popup.watchBeforeShowing(window)
        push(content)
        followPageTitle()
    }

    public func close() {
        save()
        popup.hide()
        closed()
    }

    public var isShown: Bool { popup.isShown }

    /// The bubble's card on screen (`debug.window_list`, tests).
    public var shownFrame: CGRect? { popup.isShown ? popup.cardFrame : nil }

    private func makePage() -> BrowserChromeWebHost? {
        guard let made = BrowserChromeWebHost.bookmarkEdit() else { return nil }
        made.onMessage = { [weak self] kind, params in self?.received(kind, params) }
        let card = Glass.makeOverlayPanel(content: made.view, cornerRadius: PopupStyle.standard.cornerRadius)
        popup.panel.adoptPopupStyle(card: card)
        content = made
        return made
    }

    private func push(_ content: BrowserChromeWebHost) {
        revision += 1
        content.push(["revision": revision, "isNew": isNew, "title": draft.title, "folder": draft.folder,
                      "folders": folders.foundationObject, "width": Self.width])
    }

    private func received(_ kind: String, _ params: [String: Any]) {
        guard !finished else { return }
        switch kind {
        case "size":
            guard let height = (params["height"] as? NSNumber)?.doubleValue, height > 0,
                  (params["revision"] as? NSNumber)?.intValue == revision else { return }
            present(height: ceil(height))
        case "command":
            if let title = params["title"] as? String, let folder = params["folder"] as? String {
                draft = Result(title: title, folder: folder)
            }
            switch params["type"] as? String {
            case "done": close()
            case "remove":
                finished = true
                onRemove()
                popup.hide()
                closed()
            case "more":
                close()
                onMore()
            default: break
            }
        default:
            break
        }
    }

    private func present(height: CGFloat) {
        guard let anchor, let window = anchor.window else { return }
        let size = CGSize(width: Self.width, height: height)
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        if presentsOnSize {
            presentsOnSize = false
            guard popup.show(size: size, anchor: rect, in: window, preferred: anchor.toolbarPopupSide, trailing: true,
                             makeKey: true) != nil else { return close() }
            content?.focus()
        } else if popup.isShown {
            popup.show(size: size, anchor: rect, in: window, preferred: anchor.toolbarPopupSide, trailing: true)
        }
    }

    /// While the bubble shows, a page title that arrives (or changes) becomes the name, unless the
    /// person edited the name. The star saves the bookmark at once, often before the page has a title.
    private func followPageTitle() {
        guard let pageTitle, BookmarkEditBubble.current === self, !finished else { return }
        let title = withObservationTracking { pageTitle() } onChange: { [weak self] in
            // task-owner: one hop to the main actor per title change; ends at once
            Task { @MainActor in self?.followPageTitle() }
        }
        guard let title, !title.isEmpty, title != filledTitle, draft.title == filledTitle, let content else { return }
        filledTitle = title
        draft.title = title
        push(content)
    }

    private func save() {
        guard !finished else { return }
        finished = true
        onSave(draft)
    }

    private func closed() {
        save()
        presentsOnSize = false
        if BookmarkEditBubble.current === self { BookmarkEditBubble.current = nil }
        content?.close()
        content = nil
    }
}
