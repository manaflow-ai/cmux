import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit

var cmuxWindowBrowserPortalKey: UInt8 = 0
var cmuxWindowBrowserPortalCloseObserverKey: UInt8 = 0
var cmuxBrowserSearchOverlayPanelIdAssociationKey: UInt8 = 0
private var cmuxBrowserPortalNeedsRenderingStateReattachKey: UInt8 = 0
private var cmuxWindowInteractiveSplitDividerDragKey: UInt8 = 0

#if DEBUG
func browserPortalDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

func browserPortalDebugFrame(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}
#endif

private extension NSObject {
    @discardableResult
    func browserPortalCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }
}

extension NSResponder {
    var browserPortalOwningView: NSView? {
        if let editor = self as? NSTextView,
           editor.isFieldEditor,
           let editedView = editor.delegate as? NSView {
            return editedView
        }
        return self as? NSView
    }
}

extension NSWindow {
    var browserPortalHasInteractiveSplitDividerDrag: Bool {
        get {
            let isActive =
                (objc_getAssociatedObject(self, &cmuxWindowInteractiveSplitDividerDragKey) as? NSNumber)?
                    .boolValue ?? false
            guard isActive else { return false }
            guard (NSEvent.pressedMouseButtons & 1) != 0 else {
                objc_setAssociatedObject(
                    self,
                    &cmuxWindowInteractiveSplitDividerDragKey,
                    NSNumber(value: false),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                return false
            }
            return true
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxWindowInteractiveSplitDividerDragKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

extension WKWebView {
    private var browserPortalNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, &cmuxBrowserPortalNeedsRenderingStateReattachKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxBrowserPortalNeedsRenderingStateReattachKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var browserPortalRequiresRenderingStateReattach: Bool {
        browserPortalNeedsRenderingStateReattach
    }

    func browserPortalNotifyHidden(reason: String) {
        browserPortalNeedsRenderingStateReattach = true
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPortalCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            cmuxDebugLog(
                "browser.portal.webview.hidden web=\(browserPortalDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    func browserPortalReattachRenderingState(reason: String) {
        guard browserPortalNeedsRenderingStateReattach else { return }
        guard window != nil else { return }
        browserPortalNeedsRenderingStateReattach = false

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPortalCallVoidIfAvailable($0)
        }

        if let scrollView = enclosingScrollView {
            scrollView.needsLayout = true
            scrollView.needsDisplay = true
            scrollView.setNeedsDisplay(scrollView.bounds)
            scrollView.contentView.needsLayout = true
            scrollView.contentView.needsDisplay = true
        }

        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)

#if DEBUG
        if !firedSelectors.isEmpty {
            cmuxDebugLog(
                "browser.portal.webview.reattach web=\(browserPortalDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(browserPortalDebugFrame(frame))"
            )
        }
#endif
    }
}

@MainActor
final class WindowBrowserPortal: NSObject {
    weak var window: NSWindow?
    let hostView = WindowBrowserHostView(frame: .zero)
    weak var installedContainerView: NSView?
    weak var installedReferenceView: NSView?
    var hasDeferredFullSyncScheduled = false
    var hasExternalGeometrySyncScheduled = false
    var geometryObservers: [NSObjectProtocol] = []
    // Keep generations monotonic even if a pending entry is cleared during hide/detach churn.
    var nextHostedWebViewRefreshGeneration: UInt64 = 0
    var pendingHostedWebViewRefreshes: [ObjectIdentifier: PendingHostedWebViewRefresh] = [:]

    struct Entry {
        weak var webView: WKWebView?
        weak var containerView: WindowBrowserSlotView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
        var dropZone: DropZone?
        var paneDropContext: BrowserPaneDropContext?
        var searchOverlay: BrowserPortalSearchOverlayConfiguration?
        var omnibarSuggestions: BrowserPortalOmnibarSuggestionsConfiguration?
        var paneTopChromeHeight: CGFloat
        var transientRecoveryReason: String?
        var transientRecoveryRetriesRemaining: Int
    }

    struct PendingHostedWebViewRefresh {
        var generation: UInt64 = 0
        var asyncWorkItem: DispatchWorkItem?
        var delayedWorkItem: DispatchWorkItem?
    }

    var entriesByWebViewId: [ObjectIdentifier: Entry] = [:]
    var webViewByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    init(window: NSWindow) {
        self.window = window
        super.init()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.translatesAutoresizingMaskIntoConstraints = true
        hostView.autoresizingMask = []
        installGeometryObservers(for: window)
        _ = ensureInstalled()
    }

#if DEBUG
    func debugEntryCount() -> Int {
        entriesByWebViewId.count
    }

    func debugHostedSubviewCount() -> Int {
        hostView.subviews.count
    }
#endif

    func debugSnapshot(forWebViewId webViewId: ObjectIdentifier) -> BrowserWindowPortalRegistry.DebugSnapshot? {
        guard let entry = entriesByWebViewId[webViewId] else { return nil }
        let frameInWindow: CGRect = {
            guard let container = entry.containerView, container.window != nil else { return .zero }
            return container.convert(container.bounds, to: nil)
        }()
        return BrowserWindowPortalRegistry.DebugSnapshot(
            visibleInUI: entry.visibleInUI,
            containerHidden: entry.containerView?.isHidden ?? true,
            frameInWindow: frameInWindow
        )
    }

    func webViewAtWindowPoint(_ windowPoint: NSPoint) -> WKWebView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)
        for subview in hostView.subviews.reversed() {
            guard let container = subview as? WindowBrowserSlotView else { continue }
            guard !container.isHidden else { continue }
            guard container.frame.contains(point) else { continue }
            guard let webView = entriesByWebViewId
                .first(where: { _, entry in entry.containerView === container })?
                .value
                .webView else { continue }
            return webView
        }
        return nil
    }

    func browserPaneDropTargetAtWindowPoint(_ windowPoint: NSPoint) -> BrowserPaneDropTargetView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)
        for subview in hostView.subviews.reversed() {
            guard let container = subview as? WindowBrowserSlotView else { continue }
            guard !container.isHidden else { continue }
            guard container.frame.contains(point) else { continue }
            let pointInContainer = container.convert(point, from: hostView)
            return container.paneDropTargetForDrop(at: pointInContainer)
        }
        return nil
    }
}

