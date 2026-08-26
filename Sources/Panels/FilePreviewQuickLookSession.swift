import AppKit
import Foundation
import Quartz

@MainActor
protocol FilePreviewQuickLookRefreshing: AnyObject {
    var displayState: Any! { get set }
    func refreshPreviewItem()
}

extension QLPreviewView: FilePreviewQuickLookRefreshing {}

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
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) -> NSView {
        let view = Self.makeView()
        liveViews.add(view)
        configure(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
        return view
    }

    func update(
        _ view: NSView,
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        guard liveViews.contains(view) else { return }
        configure(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func dismantle(_ view: NSView) {
        guard liveViews.contains(view) else { return }
        liveViews.remove(view)
        if liveViews.allObjects.isEmpty {
            item = nil
            itemRevision = nil
        }
        // Retire the root only after the session has forgotten it and any
        // last shared item. AppKit teardown can synchronously re-enter a
        // representable update while the old QLPreviewView is deactivated.
        Self.releaseView(view)
    }

    func close() {
        let views = liveViews.allObjects
        // A preview root can synchronously re-enter SwiftUI while AppKit
        // detaches its inner QLPreviewView. Remove every root from the session
        // before invoking teardown so that re-entrant updates cannot configure
        // a retiring representable.
        liveViews.removeAllObjects()
        item = nil
        itemRevision = nil
        for view in views {
            Self.releaseView(view)
        }
    }

    private static func makeView() -> NSView {
        FilePreviewQuickLookContainerView.make()
    }

    private static func releaseView(_ view: NSView) {
        if let container = view as? FilePreviewQuickLookContainerView {
            container.dismantle()
        } else {
            view.removeFromSuperview()
        }
    }

    private func configure(
        _ view: NSView,
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        view.isHidden = !isVisibleInUI
        if let container = view as? FilePreviewQuickLookContainerView,
           let previewView = container.livePreviewView() {
            panel.attachPreviewFocus(root: container, primaryResponder: previewView, intent: .quickLook)
            updatePreviewItem(
                for: panel.fileURL,
                title: panel.displayTitle,
                revision: revision
            )
        }
        FilePreviewNativeBackground.applyRootLayer(
            to: view,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    private func updatePreviewItem(for url: URL, title: String, revision: Int) {
        if item == nil || item?.url != url || item?.title != title {
            let nextItem = FilePreviewQLItem(url: url, title: title)
            item = nextItem
            itemRevision = revision
            for previewView in livePreviewViews() {
                previewView.previewItem = nextItem
            }
            return
        }

        guard let item else { return }
        let previewViews = livePreviewViews()
        for previewView in previewViews where previewView.previewItem !== item {
            previewView.previewItem = item
        }
        guard itemRevision != revision else { return }
        for previewView in previewViews {
            Self.refreshPreservingDisplayState(previewView)
        }
        itemRevision = revision
    }

    static func refreshPreservingDisplayState(_ previewView: some FilePreviewQuickLookRefreshing) {
        let displayState = previewView.displayState
        previewView.refreshPreviewItem()
        if let displayState {
            previewView.displayState = displayState
        }
    }

    private func livePreviewViews() -> [QLPreviewView] {
        liveViews.allObjects.compactMap {
            ($0 as? FilePreviewQuickLookContainerView)?.livePreviewView()
        }
    }
}
