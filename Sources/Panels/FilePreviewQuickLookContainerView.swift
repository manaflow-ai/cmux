import AppKit
import Quartz

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
final class FilePreviewQuickLookContainerView: QLPreviewView {
    private var previewView: TrackedQLPreviewView?

    private init?(previewFrame: NSRect) {
        super.init(frame: previewFrame, style: .normal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    static func make() -> FilePreviewQuickLookContainerView? {
        FilePreviewQuickLookContainerView(previewFrame: .zero)
    }

    override var previewItem: QLPreviewItem! {
        get {
            previewView?.previewItem
        }
        set {
            guard let newValue else {
                previewView?.previewItem = nil
                return
            }
            livePreviewView()?.previewItem = newValue
        }
    }

    /// Returns a preview view that is safe to receive a non-nil preview item,
    /// recreating it when the previous instance has been deactivated by a
    /// window detachment. Returns `nil` only if `QLPreviewView` itself fails to
    /// initialize.
    func livePreviewView() -> QLPreviewView? {
        let staleReason: String?
        if let previewView, previewView.didDetachFromWindow {
            staleReason = "detach-flag"
        } else if let previewView, window != nil, previewView.window == nil {
            staleReason = "window-nil"
        } else {
            staleReason = nil
        }

        if let previewView, staleReason == nil {
            return previewView
        }

        // Retire a deactivated instance before mounting a fresh one. Assigning
        // `nil` is always safe (the assertion's `item == nil` branch holds).
        if let stale = previewView {
            sentryBreadcrumb(
                "quickLook.preview.retire",
                category: "filePreview",
                data: ["reason": staleReason ?? "unknown"]
            )
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
        previewItem = nil
    }
}
