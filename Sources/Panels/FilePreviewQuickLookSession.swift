import AppKit
import Foundation
import Quartz

private final class FilePreviewQLItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? {
        url
    }

    var previewItemTitle: String? {
        title
    }
}

@MainActor
final class FilePreviewQuickLookSession {
    private let liveViews = NSHashTable<NSView>.weakObjects()
    private var item: FilePreviewQLItem?
    private var itemRevision: Int?

    deinit {
        // AppKit teardown is performed explicitly by close() on the main actor.
    }

    func view(
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) -> NSView {
        let view = Self.makeView()
        liveViews.add(view)
        configure(
            view,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
        return view
    }

    func update(
        _ view: NSView,
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        guard liveViews.contains(view) else { return }
        configure(
            view,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func dismantle(_ view: NSView) {
        guard liveViews.contains(view) else { return }
        liveViews.remove(view)
        Self.releaseView(view)
        if liveViews.allObjects.isEmpty {
            item = nil
            itemRevision = nil
        }
    }

    func close() {
        for view in liveViews.allObjects {
            Self.releaseView(view)
        }
        liveViews.removeAllObjects()
        item = nil
        itemRevision = nil
    }

    private static func makeView() -> NSView {
        FilePreviewQuickLookContainerView.make() ?? NSView()
    }

    private static func releaseView(_ view: NSView) {
        // QLPreviewView.close() asserts when the view is inactive and makes the
        // view permanently reject future items. Session retirement handles stale
        // updates; clearing the item releases the active preview.
        (view as? FilePreviewQuickLookContainerView)?.clearPreviewItem()
        view.removeFromSuperview()
    }

    private func configure(
        _ view: NSView,
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        view.isHidden = !isVisibleInUI
        if let container = view as? FilePreviewQuickLookContainerView,
           let previewView = container.livePreviewView() {
            panel.attachPreviewFocus(root: container, primaryResponder: previewView, intent: .quickLook)
            previewView.previewItem = previewItem(
                for: panel.fileURL,
                title: panel.displayTitle,
                revision: panel.previewRevision
            )
        }
        FilePreviewNativeBackground.applyRootLayer(
            to: view,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    private func previewItem(for url: URL, title: String, revision: Int) -> FilePreviewQLItem {
        if let item, item.url == url, item.title == title, itemRevision == revision {
            return item
        }
        let next = FilePreviewQLItem(url: url, title: title)
        item = next
        itemRevision = revision
        return next
    }
}
