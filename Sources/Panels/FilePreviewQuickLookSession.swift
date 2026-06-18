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

/// `QLPreviewView` subclass that records when AppKit removes it from its window.
///
/// QuickLook moves a preview view into its deactivated internal state when the
/// view leaves the window hierarchy. Once deactivated, assigning a non-nil
/// preview item trips a fatal QuickLook assertion
/// (`-[QLPreviewView setPreviewItem:blockingUntilLoading:timeoutDate:transition:]:`
/// `item == nil || _reserved->internalState != QLPreviewDeactivatedInternalState`)
/// which calls `abort()`. There is no public API to read that internal state, so
/// we track window detachment ourselves and let the owning container retire a
/// detached instance instead of reusing it.
private final class TrackedQLPreviewView: QLPreviewView {
    private(set) var didDetachFromWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `viewDidMoveToWindow` fires both on attach (window != nil) and detach
        // (window == nil). Only the detach transition deactivates the view.
        if window == nil {
            didDetachFromWindow = true
        }
    }
}

/// Stable host for a `QLPreviewView`.
///
/// SwiftUI keeps the `NSView` returned from `makeNSView` mounted across tab
/// switches, visibility toggles, and panel reuse, and hands that same instance
/// back to `updateNSView`. A bare `QLPreviewView` cannot survive that lifecycle:
/// once SwiftUI/AppKit detaches it from a window the view deactivates, and the
/// next `previewItem` assignment aborts the process (see `TrackedQLPreviewView`).
///
/// By vending this container to SwiftUI instead, the fragile `QLPreviewView` can
/// be swapped for a fresh one whenever the previous instance has been
/// deactivated, without SwiftUI ever re-mounting the representable.
private final class FilePreviewQuickLookContainerView: NSView {
    private var previewView: TrackedQLPreviewView?

    /// Returns a preview view that is safe to receive a non-nil preview item,
    /// recreating it when the previous instance has been deactivated by a
    /// window detachment. Returns `nil` only if `QLPreviewView` itself fails to
    /// initialize.
    func livePreviewView() -> QLPreviewView? {
        if let previewView, !previewView.didDetachFromWindow {
            return previewView
        }

        // Retire a deactivated instance before mounting a fresh one. Assigning
        // `nil` is always safe (the assertion's `item == nil` branch holds).
        if let stale = previewView {
            stale.previewItem = nil
            stale.removeFromSuperview()
        }
        previewView = nil

        guard let fresh = TrackedQLPreviewView(frame: bounds, style: .normal) else {
            return nil
        }
        fresh.autostarts = true
        fresh.autoresizingMask = [.width, .height]
        addSubview(fresh)
        previewView = fresh
        return fresh
    }

    /// Clears the active preview item without deactivating the view, mirroring
    /// the previous `releaseView` behavior.
    func clearPreviewItem() {
        previewView?.previewItem = nil
    }
}

@MainActor
final class FilePreviewQuickLookSession {
    private let liveViews = NSHashTable<NSView>.weakObjects()
    private var item: FilePreviewQLItem?

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
        }
    }

    func close() {
        for view in liveViews.allObjects {
            Self.releaseView(view)
        }
        liveViews.removeAllObjects()
        item = nil
    }

    private static func makeView() -> NSView {
        FilePreviewQuickLookContainerView()
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
            previewView.previewItem = previewItem(for: panel.fileURL, title: panel.displayTitle)
        }
        FilePreviewNativeBackground.applyRootLayer(
            to: view,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    private func previewItem(for url: URL, title: String) -> FilePreviewQLItem {
        if let item, item.url == url, item.title == title {
            return item
        }
        let next = FilePreviewQLItem(url: url, title: title)
        item = next
        return next
    }
}
