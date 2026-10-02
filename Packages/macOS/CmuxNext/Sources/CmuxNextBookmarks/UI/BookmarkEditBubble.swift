public import AppKit
import CmuxNextDesign
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
/// on close).
@MainActor
public final class BookmarkEditBubble: NSObject, NSPopoverDelegate {
    public struct Result: Sendable {
        public var title: String
        public var folder: String
    }

    private let popover = NSPopover()
    private let model: BookmarkEditModel
    private var finished = false
    private let onSave: (Result) -> Void
    private let onRemove: () -> Void
    private let onMore: () -> Void
    /// The open bubble, so a second press on the star closes it.
    public private(set) static var current: BookmarkEditBubble?

    public init(isNew: Bool, title: String, folder: String, folders: [BookmarkFolderChoice],
                onSave: @escaping (Result) -> Void, onRemove: @escaping () -> Void, onMore: @escaping () -> Void) {
        model = BookmarkEditModel(isNew: isNew, title: title, folder: folder, folders: folders)
        self.onSave = onSave
        self.onRemove = onRemove
        self.onMore = onMore
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    public func show(relativeTo anchor: NSView) {
        BookmarkEditBubble.current?.close()
        BookmarkEditBubble.current = self
        model.colors = anchor.performWithTheme { BookmarkPageColors.resolve() }
        model.onDone = { [weak self] in self?.close() }
        model.onRemove = { [weak self] in
            guard let self else { return }
            finished = true
            onRemove()
            popover.performClose(nil)
        }
        model.onMore = { [weak self] in
            self?.close()
            self?.onMore()
        }
        let hosting = NSHostingController(rootView: BookmarkEditView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }

    public func close() {
        save()
        popover.performClose(nil)
    }

    public var isShown: Bool { popover.isShown }

    private func save() {
        guard !finished else { return }
        finished = true
        onSave(Result(title: model.title, folder: model.folder))
    }

    public func popoverDidClose(_ notification: Notification) {
        save()
        if BookmarkEditBubble.current === self { BookmarkEditBubble.current = nil }
    }
}
