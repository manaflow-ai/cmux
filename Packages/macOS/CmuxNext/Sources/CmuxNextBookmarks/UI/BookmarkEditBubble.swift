public import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// A folder choice in the edit bubble and editor sheets: indented by depth.
public struct BookmarkFolderChoice: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var depth: Int

    /// Every folder of `tree` under its roots, in tree order.
    public static func all(in tree: BookmarkTree, barTitle: String, otherTitle: String) -> [BookmarkFolderChoice] {
        var result: [BookmarkFolderChoice] = []
        func visit(_ parent: String, depth: Int) {
            for node in tree.children(of: parent) where node.isFolder {
                result.append(BookmarkFolderChoice(id: node.id, title: node.displayTitle, depth: depth))
                visit(node.id, depth: depth + 1)
            }
        }
        result.append(BookmarkFolderChoice(id: BookmarkRoot.bar.rawValue, title: barTitle, depth: 0))
        visit(BookmarkRoot.bar.rawValue, depth: 1)
        result.append(BookmarkFolderChoice(id: BookmarkRoot.other.rawValue, title: otherTitle, depth: 0))
        visit(BookmarkRoot.other.rawValue, depth: 1)
        return result
    }
}

/// The "Bookmark added" / "Edit bookmark" bubble from the omnibar star:
/// Name, Folder, Remove, Done, and More… for the manager. Return or Done
/// saves; Escape or a click outside closes and also saves (edits are kept
/// on close). It is a popup of the shared native host (`NativePopupHost`,
/// hq REUSE.md slice 1): a child panel of the browser window under the star,
/// in the popup style, that takes the keys only while the app is active. It
/// was an `NSPopover`, whose transient behavior breaks while the app is
/// not active (nxdog34) and which drew the system arrow chrome.
@MainActor
public final class BookmarkEditBubble: NSObject {
    public struct Result: Sendable {
        public var title: String
        public var folder: String
    }

    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.bookmarks.edit"))
    private let model: BookmarkEditModel
    private var finished = false
    private let onSave: (Result) -> Void
    private let onRemove: () -> Void
    private let onMore: () -> Void
    /// The page's title now (observable): a new bookmark made before the page had a title takes
    /// it when it arrives, unless the name was edited.
    private let pageTitle: (() -> String?)?
    /// The name the bubble filled in last (from the page); a different name is the user's.
    private var filledTitle: String
    /// The open bubble, so a second press on the star closes it.
    public private(set) static var current: BookmarkEditBubble?

    public init(isNew: Bool, title: String, folder: String, folders: [BookmarkFolderChoice],
                pageTitle: (() -> String?)? = nil,
                onSave: @escaping (Result) -> Void, onRemove: @escaping () -> Void, onMore: @escaping () -> Void) {
        model = BookmarkEditModel(isNew: isNew, title: title, folder: folder, folders: folders)
        self.pageTitle = isNew ? pageTitle : nil
        filledTitle = title
        self.onSave = onSave
        self.onRemove = onRemove
        self.onMore = onMore
        super.init()
        // A dismiss (click outside, Escape, the app or window going away) keeps the edits.
        popup.onDismiss = { [weak self] in self?.closed() }
    }

    public func show(relativeTo anchor: NSView) {
        BookmarkEditBubble.current?.close()
        guard let window = anchor.window else { return }
        model.colors = anchor.performWithTheme { BookmarkPageColors.resolve() }
        model.onDone = { [weak self] in self?.close() }
        model.onRemove = { [weak self] in
            guard let self else { return }
            finished = true
            onRemove()
            popup.hide()
            closed()
        }
        model.onMore = { [weak self] in
            self?.close()
            self?.onMore()
        }
        let content = NSHostingView(rootView: BookmarkEditView(model: model))
        let card = Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius)
        popup.panel.adoptPopupStyle(card: card)
        popup.panel.adoptThemeScope(of: anchor)
        // A press on the star toggles the bubble: the star closes it, not the click monitor.
        popup.keepsOpen = { [weak anchor] event in
            guard let anchor, event.window === anchor.window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        let size = content.fittingSize
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        if popup.show(size: CGSize(width: ceil(size.width), height: ceil(size.height)), anchor: rect, in: window,
                      preferred: anchor.toolbarPopupSide, trailing: true, makeKey: true) != nil {
            BookmarkEditBubble.current = self
            followPageTitle()
        }
    }

    /// While the bubble shows, a page title that arrives (or changes) becomes the name, unless the
    /// user edited the name. The star saves the bookmark at once, often before the page has a title.
    private func followPageTitle() {
        guard let pageTitle, popup.isShown, !finished else { return }
        let title = withObservationTracking { pageTitle() } onChange: { [weak self] in
            Task { @MainActor in self?.followPageTitle() }
        }
        guard let title, !title.isEmpty, title != filledTitle, model.title == filledTitle else { return }
        filledTitle = title
        model.title = title
    }

    public func close() {
        save()
        popup.hide()
        closed()
    }

    public var isShown: Bool { popup.isShown }

    /// The bubble's card on screen (`debug.window_list`, tests).
    public var shownFrame: CGRect? { popup.isShown ? popup.cardFrame : nil }

    private func save() {
        guard !finished else { return }
        finished = true
        onSave(Result(title: model.title, folder: model.folder))
    }

    private func closed() {
        save()
        if BookmarkEditBubble.current === self { BookmarkEditBubble.current = nil }
    }
}
