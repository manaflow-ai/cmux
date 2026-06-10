import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Hosted Web Content & Geometry
extension WebViewRepresentable.HostContainerView {
        func containsManagedLocalInlineContent(_ view: NSView) -> Bool {
            if let localInlineSlotView,
               view === localInlineSlotView || view.isDescendant(of: localInlineSlotView) {
                return true
            }
            if let hostedInspectorSideDockContainerView,
               view === hostedInspectorSideDockContainerView || view.isDescendant(of: hostedInspectorSideDockContainerView) {
                return true
            }
            return false
        }

        func currentHostedWebViewContainer(preferredSlotView: WindowBrowserSlotView) -> NSView {
            if let hostedInspectorSideDockContainerView,
               let hostedInspectorSideDockPageView,
               hostedWebView?.isDescendant(of: hostedInspectorSideDockContainerView) == true,
               hostedInspectorSideDockPageView.isDescendant(of: hostedInspectorSideDockContainerView) {
                return hostedInspectorSideDockContainerView
            }
            return preferredSlotView
        }

        func setHostedInspectorFrontendWebView(_ webView: WKWebView?) {
            hostedInspectorFrontendWebView = webView
            lastHostedInspectorManualSideDockAllowed = nil
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "setHostedInspectorFrontendWebView")
        }

        var hasStoredHostedInspectorWidthPreference: Bool {
            preferredHostedInspectorWidth != nil || preferredHostedInspectorWidthFraction != nil
        }

#if DEBUG
        private static func shouldLogPointerEvent(_ event: NSEvent?) -> Bool {
            switch event?.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                return true
            default:
                return false
            }
        }

        func debugLogHitTest(stage: String, point: NSPoint, passThrough: Bool, hitView: NSView?) {
            let event = NSApp.currentEvent
            guard Self.shouldLogPointerEvent(event) else { return }

            let hitDesc: String = {
                guard let hitView else { return "nil" }
                let token = Unmanaged.passUnretained(hitView).toOpaque()
                return "\(type(of: hitView))@\(token)"
            }()
            let hostRectInContent: NSRect = {
                guard let window, let contentView = window.contentView else { return .zero }
                return contentView.convert(bounds, from: self)
            }()
            cmuxDebugLog(
                "browser.panel.host stage=\(stage) event=\(String(describing: event?.type)) " +
                "point=\(String(format: "%.1f,%.1f", point.x, point.y)) pass=\(passThrough ? 1 : 0) " +
                "hostFrameInContent=\(String(format: "%.1f,%.1f %.1fx%.1f", hostRectInContent.origin.x, hostRectInContent.origin.y, hostRectInContent.width, hostRectInContent.height)) " +
                "hit=\(hitDesc)"
            )
        }

        static func debugObjectID(_ object: AnyObject?) -> String {
            guard let object else { return "nil" }
            return String(describing: Unmanaged.passUnretained(object).toOpaque())
        }

        static func debugRect(_ rect: NSRect) -> String {
            String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
        }

        func debugLogHostedInspectorFrames(
            stage: String,
            point: NSPoint? = nil,
            hit: HostedInspectorDividerHit
        ) {
            let pointDesc = point.map { String(format: "%.1f,%.1f", $0.x, $0.y) } ?? "nil"
            let preferredWidthDesc = preferredHostedInspectorWidth.map { String(format: "%.1f", $0) } ?? "nil"
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(stage) point=\(pointDesc) " +
                "host=\(Self.debugObjectID(self)) container=\(Self.debugObjectID(hit.containerView)) " +
                "page=\(Self.debugObjectID(hit.pageView)) inspector=\(Self.debugObjectID(hit.inspectorView)) " +
                "preferredWidth=\(preferredWidthDesc) " +
                "hostFrame=\(Self.debugRect(frame)) hostBounds=\(Self.debugRect(bounds)) " +
                "containerBounds=\(Self.debugRect(hit.containerView.bounds)) " +
                "pageFrame=\(Self.debugRect(hit.pageView.frame)) " +
                "inspectorFrame=\(Self.debugRect(hit.inspectorView.frame))"
            )
        }

        func debugLogHostedInspectorLayoutIfNeeded(reason: String) {
            guard let hit = hostedInspectorDividerCandidate() else {
                if !hasLoggedMissingHostedInspectorCandidate,
                   lastLoggedHostedInspectorFrames != nil || preferredHostedInspectorWidth != nil {
                    let preferredWidthDesc = preferredHostedInspectorWidth.map {
                        String(format: "%.1f", $0)
                    } ?? "nil"
                    lastLoggedHostedInspectorFrames = nil
                    hasLoggedMissingHostedInspectorCandidate = true
                    cmuxDebugLog(
                        "browser.panel.hostedInspector stage=\(reason).candidateMissing " +
                        "host=\(Self.debugObjectID(self)) preferredWidth=\(preferredWidthDesc)"
                    )
                }
                return
            }
            hasLoggedMissingHostedInspectorCandidate = false

            let nextFrames = (page: hit.pageView.frame, inspector: hit.inspectorView.frame)
            if let lastLoggedHostedInspectorFrames,
               Self.rectApproximatelyEqual(lastLoggedHostedInspectorFrames.page, nextFrames.page),
               Self.rectApproximatelyEqual(lastLoggedHostedInspectorFrames.inspector, nextFrames.inspector) {
                return
            }

            lastLoggedHostedInspectorFrames = nextFrames
            debugLogHostedInspectorFrames(stage: "\(reason).layout", hit: hit)
        }
#endif

        static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.5) -> Bool {
            abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
                abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
                abs(lhs.width - rhs.width) <= epsilon &&
                abs(lhs.height - rhs.height) <= epsilon
        }

        static func sizeApproximatelyEqual(_ lhs: NSSize, _ rhs: NSSize, epsilon: CGFloat = 0.5) -> Bool {
            abs(lhs.width - rhs.width) <= epsilon &&
                abs(lhs.height - rhs.height) <= epsilon
        }

        private func currentGeometryState() -> GeometryState {
            GeometryState(
                frame: frame,
                bounds: bounds,
                windowNumber: window?.windowNumber,
                superviewID: superview.map(ObjectIdentifier.init)
            )
        }

        /// Record that geometry changed without firing the callback immediately.
        /// `setFrameOrigin`/`setFrameSize` can fire multiple times before `layout()`;
        /// deferring avoids redundant portal-sync cascades during divider drag.
        /// A dispatch fallback ensures the callback fires even if `layout()` is not called.
        /// Note: `lastReportedGeometryState` and `geometryRevision` are only updated
        /// when the callback actually fires, so `updateNSView` sees a revision that
        /// is strictly tied to emitted callbacks (no premature increments).
        func markGeometryDirtyIfNeeded() {
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            guard !hasPendingGeometryNotification else { return }
            hasPendingGeometryNotification = true
            DispatchQueue.main.async { [weak self] in
                self?.notifyGeometryChangedIfNeeded()
            }
        }

        /// Check for geometry changes and fire the callback. Also flushes any pending
        /// dirty state from `markGeometryDirtyIfNeeded` so `layout()` supersedes the
        /// async fallback.  Only updates `lastReportedGeometryState` / `geometryRevision`
        /// when the callback is emitted, keeping the revision in sync with actual
        /// notifications.
        func notifyGeometryChangedIfNeeded() {
            hasPendingGeometryNotification = false
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            lastReportedGeometryState = state
            geometryRevision &+= 1
            onGeometryChanged?()
        }

        func ensureLocalInlineSlotView() -> WindowBrowserSlotView {
            if let localInlineSlotView, localInlineSlotView.superview === self {
                localInlineSlotView.isHidden = false
                return localInlineSlotView
            }

            let slotView = WindowBrowserSlotView(frame: bounds)
            slotView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(slotView, positioned: .above, relativeTo: nil)
            localInlineSlotConstraints = [
                slotView.topAnchor.constraint(equalTo: topAnchor),
                slotView.bottomAnchor.constraint(equalTo: bottomAnchor),
                slotView.leadingAnchor.constraint(equalTo: leadingAnchor),
                slotView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(localInlineSlotConstraints)
            localInlineSlotView = slotView
            return slotView
        }

        func setLocalInlineSlotHidden(_ hidden: Bool) {
            localInlineSlotView?.isHidden = hidden
            if hidden {
                notifyHostedWebKitHidden(reason: "slotHidden")
            }
        }

        func clearLocalInlineCallbacks() {
            onPreferredHostedInspectorWidthChanged = nil
            localInlineSlotView?.onHostedInspectorLayout = nil
        }

        private func appendHostedWebKitSubviews(
            in root: NSView,
            to result: inout [WKWebView],
            seen: inout Set<ObjectIdentifier>
        ) {
            if let webView = root as? WKWebView {
                guard !webView.cmuxBrowserPanelIsInspectorFrontend else { return }
                let id = ObjectIdentifier(webView)
                if seen.insert(id).inserted {
                    result.append(webView)
                }
            }
            for subview in root.subviews {
                appendHostedWebKitSubviews(in: subview, to: &result, seen: &seen)
            }
        }

        private var hostedWebKitSubviews: [WKWebView] {
            var result: [WKWebView] = []
            var seen = Set<ObjectIdentifier>()

            func append(_ webView: WKWebView?) {
                guard let webView else { return }
                guard !webView.cmuxBrowserPanelIsInspectorFrontend else { return }
                let id = ObjectIdentifier(webView)
                guard seen.insert(id).inserted else { return }
                result.append(webView)
            }

            append(hostedWebView)
            appendHostedWebKitSubviews(in: self, to: &result, seen: &seen)
            return result
        }

        func notifyHostedWebKitHidden(reason: String) {
            for webView in hostedWebKitSubviews {
                webView.cmuxBrowserPanelNotifyHidden(reason: reason)
            }
        }

        func refreshHostedWebKitPresentation(
            reason: String,
            forceLifecycleRefresh: Bool = false
        ) {
            guard let localInlineSlotView else { return }
            guard !localInlineSlotView.isHidden else { return }
            let hostedWebKitSubviews = hostedWebKitSubviews
            guard !hostedWebKitSubviews.isEmpty else { return }

            localInlineSlotView.needsLayout = true
            localInlineSlotView.needsDisplay = true
            localInlineSlotView.setNeedsDisplay(localInlineSlotView.bounds)

            needsLayout = true
            needsDisplay = true
            setNeedsDisplay(bounds)

            for webView in hostedWebKitSubviews {
                if let scrollView = webView.enclosingScrollView {
                    scrollView.needsLayout = true
                    scrollView.needsDisplay = true
                    scrollView.setNeedsDisplay(scrollView.bounds)
                    scrollView.contentView.needsLayout = true
                    scrollView.contentView.needsDisplay = true
                }
                webView.needsLayout = true
                webView.needsDisplay = true
                webView.setNeedsDisplay(webView.bounds)
            }

            localInlineSlotView.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()

            for webView in hostedWebKitSubviews {
                if let scrollView = webView.enclosingScrollView {
                    scrollView.layoutSubtreeIfNeeded()
                    scrollView.contentView.layoutSubtreeIfNeeded()
                    scrollView.displayIfNeeded()
                }
                webView.layoutSubtreeIfNeeded()
                if forceLifecycleRefresh {
                    webView.cmuxBrowserPanelForceRenderingStateRefresh(reason: reason)
                } else {
                    webView.cmuxBrowserPanelReattachRenderingState(reason: reason)
                }
                webView.displayIfNeeded()
            }

            localInlineSlotView.displayIfNeeded()
            displayIfNeeded()
            window?.displayIfNeeded()
        }

        func prepareForWindowPortalHosting() {
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            hostedInspectorDockConfigurationSyncWorkItem = nil
            notifyHostedWebKitHidden(reason: "prepareForWindowPortalHosting")
            deactivateHostedInspectorSideDockIfNeeded(reparentTo: localInlineSlotView)
            hostedInspectorFrontendWebView = nil
        }

        func clearStaleHostedInspectorOwnershipState() {
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            hostedInspectorDockConfigurationSyncWorkItem = nil
            hostedInspectorFrontendWebView = nil
            lastHostedInspectorManualSideDockAllowed = nil
        }

        func releaseHostedWebViewConstraints() {
            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebViewConstraints = []
            hostedWebView = nil
        }

        func pinHostedWebView(_ webView: WKWebView, in container: NSView) {
            guard webView.superview === container || webView.isDescendant(of: container) else { return }

            let hasCompanionWKSubviews = Self.hasWebKitCompanionSubview(
                in: container,
                primaryWebView: webView
            )
            let needsPlainWebViewFrameReset =
                webView.superview === container &&
                !hasCompanionWKSubviews &&
                Self.frameDiffersFromBounds(webView.frame, bounds: container.bounds)
            let needsFrameHosting =
                hostedWebView !== webView ||
                !hostedWebViewConstraints.isEmpty ||
                needsPlainWebViewFrameReset ||
                !webView.translatesAutoresizingMaskIntoConstraints ||
                webView.autoresizingMask != [.width, .height]
            guard needsFrameHosting else {
                needsLayout = true
                layoutSubtreeIfNeeded()
                return
            }

            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebViewConstraints = []
            hostedWebView = webView

            // WebKit's attached inspector does not reliably dock into a constraint-managed
            // WKWebView hierarchy on macOS. Host the moved webview with autoresizing and
            // preserve WebKit-managed split frames when docked DevTools siblings exist.
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            if webView.superview === container && !hasCompanionWKSubviews {
                webView.frame = container.bounds
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        private static func frameDiffersFromBounds(_ frame: NSRect, bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
            abs(frame.minX - bounds.minX) > epsilon ||
                abs(frame.minY - bounds.minY) > epsilon ||
                abs(frame.width - bounds.width) > epsilon ||
                abs(frame.height - bounds.height) > epsilon
        }

        private static func hasWebKitCompanionSubview(in host: NSView, primaryWebView: WKWebView) -> Bool {
            var stack = host.subviews.filter { $0 !== primaryWebView }
            while let current = stack.popLast() {
                if current.isDescendant(of: primaryWebView) {
                    continue
                }
                if current.isHidden || current.alphaValue <= 0 {
                    continue
                }
                if String(describing: type(of: current)).contains("WK") {
                    let width = max(current.frame.width, current.bounds.width)
                    let height = max(current.frame.height, current.bounds.height)
                    if width > 1, height > 1 {
                        return true
                    }
                    continue
                }
                stack.append(contentsOf: current.subviews)
            }
            return false
        }

}
