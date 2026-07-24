import AppKit
import Quartz

enum FilePreviewQuickLookStaleReason: String {
    case detachedFromWindow = "detached-from-window"
    case missingFromMountedContainer = "missing-from-mounted-container"
}

enum FilePreviewQuickLookReusePolicy {
    static func staleReason(
        didDetachFromWindow: Bool,
        containerHasWindow: Bool,
        previewHasWindow: Bool
    ) -> FilePreviewQuickLookStaleReason? {
        if didDetachFromWindow {
            return .detachedFromWindow
        }
        if containerHasWindow, !previewHasWindow {
            return .missingFromMountedContainer
        }
        return nil
    }

    static func shouldRetire(
        didDetachFromWindow: Bool,
        containerHasWindow: Bool,
        previewHasWindow: Bool
    ) -> Bool {
        staleReason(
            didDetachFromWindow: didDetachFromWindow,
            containerHasWindow: containerHasWindow,
            previewHasWindow: previewHasWindow
        ) != nil
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
            setLivePreviewItem(newValue)
        }
    }

    @discardableResult
    func setLivePreviewItem(_ item: QLPreviewItem) -> QLPreviewView? {
        guard let previewView = livePreviewView() else { return nil }
        previewView.previewItem = item
        return previewView
    }

    /// Returns a preview view that is safe to receive a non-nil preview item,
    /// recreating it when the previous instance has been deactivated or no
    /// longer shares its mounted container's window. Returns `nil` only if
    /// `QLPreviewView` itself fails to initialize.
    func livePreviewView() -> QLPreviewView? {
        if let previewView {
            let staleReason = FilePreviewQuickLookReusePolicy.staleReason(
                didDetachFromWindow: previewView.didDetachFromWindow,
                containerHasWindow: window != nil,
                previewHasWindow: previewView.window != nil
            )
            if let staleReason {
                sentryBreadcrumb(
                    "quickLook.preview.retire",
                    category: "filePreview",
                    data: ["reason": staleReason.rawValue]
                )
                // Assigning nil is always safe because QuickLook permits
                // clearing an item after deactivation.
                previewView.previewItem = nil
                previewView.removeFromSuperview()
                self.previewView = nil
            } else {
                return previewView
            }
        }

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
