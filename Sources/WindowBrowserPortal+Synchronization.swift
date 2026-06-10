import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


// MARK: - Host installation, anchor frame geometry & web view synchronization
extension WindowBrowserPortal {
    private static let transientRecoveryRetryBudget: Int = 12

    @discardableResult
    func ensureInstalled() -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installationTarget(for: window) else { return false }
        let placementReference = preferredHostPlacementReference(in: container, fallback: reference)

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            hostView.removeFromSuperview()
            container.addSubview(hostView, positioned: .above, relativeTo: placementReference)
            installedContainerView = container
            installedReferenceView = reference
        } else {
            let aboveReference = Self.isView(hostView, above: reference, in: container)
            let abovePlacementReference = placementReference === reference
                || Self.isView(hostView, above: placementReference, in: container)
            if !aboveReference || !abovePlacementReference {
                container.addSubview(hostView, positioned: .above, relativeTo: placementReference)
            }
        }

        synchronizeHostFrameToReference()
        return true
    }

    @discardableResult
    private func synchronizeHostFrameToReference() -> Bool {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return false
        }
        let frameInContainer = container.convert(reference.bounds, from: reference)
        let hasFiniteFrame =
            frameInContainer.origin.x.isFinite &&
            frameInContainer.origin.y.isFinite &&
            frameInContainer.size.width.isFinite &&
            frameInContainer.size.height.isFinite
        guard hasFiniteFrame else { return false }

        if !Self.rectApproximatelyEqual(hostView.frame, frameInContainer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostView.frame = frameInContainer
            CATransaction.commit()
#if DEBUG
            cmuxDebugLog(
                "browser.portal.hostFrame.update host=\(browserPortalDebugToken(hostView)) " +
                "frame=\(browserPortalDebugFrame(frameInContainer))"
            )
#endif
        }
        return frameInContainer.width > 1 && frameInContainer.height > 1
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        if let glassTarget = WindowGlassEffect.portalInstallationTarget(for: window) {
            return glassTarget
        }

        guard let contentView = window.contentView else { return nil }

        guard let themeFrame = contentView.superview else { return nil }
        return (themeFrame, contentView)
    }

    private static func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        var current = view.superview
        while let v = current {
            if v.isHidden { return true }
            current = v.superview
        }
        return false
    }

    static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.01) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    private static func pixelSnappedRect(_ rect: NSRect, in view: NSView) -> NSRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return rect
        }
        let scale = max(1.0, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        return NSRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: max(0, snap(rect.size.width)),
            height: max(0, snap(rect.size.height))
        )
    }

    /// Convert an anchor view's bounds to window coordinates while honoring ancestor clipping.
    /// SwiftUI/AppKit hosting layers can briefly report an anchor bounds rect larger than the
    /// visible split pane during rearrangement; intersecting through ancestor bounds keeps the
    /// portal locked to the pane the user can actually see.
    private func effectiveAnchorFrameInWindow(for anchorView: NSView) -> NSRect {
        var frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        var current = anchorView.superview
        while let ancestor = current {
            let ancestorBoundsInWindow = ancestor.convert(ancestor.bounds, to: nil)
            let finiteAncestorBounds =
                ancestorBoundsInWindow.origin.x.isFinite &&
                ancestorBoundsInWindow.origin.y.isFinite &&
                ancestorBoundsInWindow.size.width.isFinite &&
                ancestorBoundsInWindow.size.height.isFinite
            if finiteAncestorBounds {
                frameInWindow = frameInWindow.intersection(ancestorBoundsInWindow)
                if frameInWindow.isNull { return .zero }
            }
            if ancestor === installedReferenceView { break }
            current = ancestor.superview
        }
        return frameInWindow
    }

    private static func frameExtendsOutsideBounds(_ frame: NSRect, bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        frame.minX < bounds.minX - epsilon ||
            frame.minY < bounds.minY - epsilon ||
            frame.maxX > bounds.maxX + epsilon ||
            frame.maxY > bounds.maxY + epsilon
    }

    private static func hasVisibleInspectorDescendant(in root: NSView) -> Bool {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if current !== root {
                if cmuxIsWebInspectorObject(current),
                   !current.isHidden,
                   current.alphaValue > 0,
                   current.frame.width > 1,
                   current.frame.height > 1 {
                    return true
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    private static func inferredBottomDockedInspectorFrame(
        in containerView: NSView,
        primaryWebView: WKWebView,
        epsilon: CGFloat = 1
    ) -> NSRect? {
        let pageFrame = primaryWebView.frame
        let containerBounds = containerView.bounds

        let candidates = containerView.subviews.compactMap { candidate -> NSRect? in
            guard candidate !== primaryWebView else { return nil }
            guard hasVisibleInspectorDescendant(in: candidate) else { return nil }

            let frame = candidate.frame
            guard frame.width > 1, frame.height > 1 else { return nil }
            let overlapWidth = min(pageFrame.maxX, frame.maxX) - max(pageFrame.minX, frame.minX)
            guard overlapWidth > min(pageFrame.width, frame.width) * 0.7 else { return nil }
            guard frame.minY <= containerBounds.minY + epsilon else { return nil }
            guard frame.maxY <= pageFrame.minY + epsilon else { return nil }
            return frame
        }

        return candidates.max(by: { $0.height < $1.height })
    }

    private static func repairedBottomDockedPageFrame(
        in containerView: NSView,
        primaryWebView: WKWebView,
        epsilon: CGFloat = 0.5
    ) -> NSRect? {
        let pageFrame = primaryWebView.frame
        let containerBounds = containerView.bounds
        guard frameExtendsOutsideBounds(pageFrame, bounds: containerBounds, epsilon: epsilon),
              let inspectorFrame = inferredBottomDockedInspectorFrame(
                  in: containerView,
                  primaryWebView: primaryWebView
              ) else {
            return nil
        }

        return NSRect(
            x: containerBounds.minX,
            y: inspectorFrame.maxY,
            width: containerBounds.width,
            height: max(0, containerBounds.maxY - inspectorFrame.maxY)
        )
    }

#if DEBUG
    private static func inspectorSubviewCount(in root: NSView) -> Int {
        var stack: [NSView] = [root]
        var count = 0
        while let current = stack.popLast() {
            for subview in current.subviews {
                if cmuxIsWebInspectorObject(subview) {
                    count += 1
                }
                stack.append(subview)
            }
        }
        return count
    }
#endif

    private static func isView(_ view: NSView, above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: view),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

    private func preferredHostPlacementReference(in container: NSView, fallback reference: NSView) -> NSView {
        container.subviews.last(where: {
            $0 !== hostView && ($0 === reference || $0 is WindowTerminalHostView)
        }) ?? reference
    }

    private enum HostedWebViewPresentationUpdateKind {
        case none
        case geometryOnly
        case refresh

        private static let geometryOnlyReasons: Set<String> = [
            "frame",
            "bounds",
            "webFrame",
            "webFrameBottomDock",
        ]

        private static let refreshReasons: Set<String> = [
            "syncAttachContainer",
            "syncAttachWebView",
            "reveal",
            "transientRecovery",
            "anchor",
        ]

        static func resolve(reasons: [String]) -> Self {
            guard !reasons.isEmpty else { return .none }
            let reasonSet = Set(reasons)
            if !reasonSet.isDisjoint(with: Self.refreshReasons) {
                return .refresh
            }
            if reasonSet.isSubset(of: Self.geometryOnlyReasons) {
                return .geometryOnly
            }
            return .refresh
        }
    }

    private func resetTransientRecoveryRetryIfNeeded(forWebViewId webViewId: ObjectIdentifier, entry: inout Entry) {
        guard entry.transientRecoveryRetriesRemaining != 0 || entry.transientRecoveryReason != nil else { return }
        entry.transientRecoveryReason = nil
        entry.transientRecoveryRetriesRemaining = 0
        entriesByWebViewId[webViewId] = entry
    }

    private func scheduleTransientRecoveryRetryIfNeeded(
        forWebViewId webViewId: ObjectIdentifier,
        entry: inout Entry,
        webView: WKWebView,
        reason: String
    ) -> Bool {
        if entry.transientRecoveryReason != reason {
            entry.transientRecoveryReason = reason
            entry.transientRecoveryRetriesRemaining = Self.transientRecoveryRetryBudget
        }
#if DEBUG
        if entry.transientRecoveryRetriesRemaining <= 0 {
            cmuxDebugLog(
                "browser.portal.sync.deferRecover.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=\(reason) exhausted=1"
            )
        }
#endif
        guard entry.transientRecoveryRetriesRemaining > 0 else { return false }

        entry.transientRecoveryRetriesRemaining -= 1
        entriesByWebViewId[webViewId] = entry
#if DEBUG
        cmuxDebugLog(
            "browser.portal.sync.deferRecover web=\(browserPortalDebugToken(webView)) " +
            "reason=\(reason) remaining=\(entry.transientRecoveryRetriesRemaining)"
        )
#endif
        if entry.transientRecoveryRetriesRemaining > 0 {
            scheduleDeferredFullSynchronizeAll()
        }
        return true
    }

    func synchronizeWebView(
        withId webViewId: ObjectIdentifier,
        source: String,
        forcePresentationRefresh: Bool = false
    ) {
        guard ensureInstalled() else { return }
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard let webView = entry.webView else {
            entriesByWebViewId.removeValue(forKey: webViewId)
            return
        }
        guard let containerView = entry.containerView else {
            entriesByWebViewId.removeValue(forKey: webViewId)
            if let anchor = entry.anchorView {
                webViewByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
            }
            return
        }
        let previousTransientRecoveryReason = entry.transientRecoveryReason
        func hideContainerView(reason: String) {
            cancelPendingHostedWebViewRefreshes(for: webViewId)
            containerView.setPaneTopChromeHeight(0)
            containerView.setSearchOverlay(nil)
            containerView.setOmnibarSuggestions(nil)
            containerView.setPaneDropContext(nil)
            containerView.setPortalDragDropZone(nil)
            containerView.setDropZoneOverlay(zone: nil)
            // Tab/workspace visibility changes should hide the portal slot without forcing
            // WebKit through `_exitInWindow`/`_enterInWindow`, which fires visibilitychange
            // and can trigger page reloads. Reserve the full lifecycle notify for cases
            // where the visible surface is actually leaving the window/render tree.
            if entry.visibleInUI, !containerView.isHidden, webView.superview === containerView {
                notifyHostedWebKitHidden(
                    in: containerView,
                    primaryWebView: webView,
                    reason: reason
                )
            }
            containerView.isHidden = true
        }
        func scheduleTransientDetachRecovery(reason: String) -> Bool {
            guard entry.visibleInUI else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: reason
            )
        }
        func preserveVisibleDuringTransientDetach(reason: String) -> Bool {
            guard entry.visibleInUI, !containerView.isHidden else { return false }
            let didScheduleTransientRecovery = scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: reason
            )
            guard didScheduleTransientRecovery else { return false }
#if DEBUG
            cmuxDebugLog(
                "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                "reason=\(reason) frame=\(browserPortalDebugFrame(containerView.frame))"
            )
#endif
            containerView.setPaneDropContext(nil)
            containerView.setPortalDragDropZone(nil)
            containerView.setDropZoneOverlay(zone: nil)
            return true
        }
        guard let anchorView = entry.anchorView, let window else {
            if preserveVisibleDuringTransientDetach(reason: "missingAnchorOrWindow") {
                return
            }
            if scheduleTransientDetachRecovery(reason: "missingAnchorOrWindow") {
                hideContainerView(reason: "missingAnchorOrWindow")
                return
            }
            if !entry.visibleInUI {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
#if DEBUG
            if !containerView.isHidden {
                cmuxDebugLog(
                    "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                    "web=\(browserPortalDebugToken(webView)) value=1 reason=missingAnchorOrWindow"
                )
            }
#endif
            hideContainerView(reason: "missingAnchorOrWindow")
            return
        }
        guard anchorView.window === window else {
            let isOffWindowReparent =
                entry.visibleInUI &&
                anchorView.window == nil &&
                anchorView.superview != nil
            if isOffWindowReparent {
                if preserveVisibleDuringTransientDetach(reason: "anchorWindowMismatch.offWindow") {
                    return
                }
                if scheduleTransientDetachRecovery(reason: "anchorWindowMismatch") {
                    hideContainerView(reason: "anchorWindowMismatch")
                    return
                }
            }
            if preserveVisibleDuringTransientDetach(reason: "anchorWindowMismatch") {
                return
            }
            if scheduleTransientDetachRecovery(reason: "anchorWindowMismatch") {
                hideContainerView(reason: "anchorWindowMismatch")
                return
            }
#if DEBUG
            if !containerView.isHidden {
                cmuxDebugLog(
                    "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                    "web=\(browserPortalDebugToken(webView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(browserPortalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            if !entry.visibleInUI {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
            hideContainerView(reason: "anchorWindowMismatch")
            return
        }

        var refreshReasons: [String] = []
        if containerView.superview !== hostView {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) " +
                "reason=syncAttach super=\(browserPortalDebugToken(containerView.superview))"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
            refreshReasons.append("syncAttachContainer")
        }
        let shouldPreserveExternalFullscreenHost =
            webView.cmuxIsManagedByExternalFullscreenWindow(relativeTo: window)
        let shouldPreserveExternalHostForHiddenEntry =
            !shouldPreserveExternalFullscreenHost &&
            !entry.visibleInUI &&
            webView.superview !== containerView
        if shouldPreserveExternalFullscreenHost {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=fullscreenExternalHost super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView)) " +
                "state=\(String(describing: webView.fullscreenState))"
            )
#endif
        } else if shouldPreserveExternalHostForHiddenEntry {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=hiddenEntryExternalHost super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
        } else if webView.superview !== containerView {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent web=\(browserPortalDebugToken(webView)) " +
                "reason=syncAttachContainer super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
            if let sourceSuperview = webView.superview {
                moveWebKitRelatedSubviewsIfNeeded(
                    from: sourceSuperview,
                    to: containerView,
                    primaryWebView: webView,
                    reason: "sync.attachContainer"
                )
            } else {
                containerView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
            containerView.pinHostedWebView(webView)
            refreshReasons.append("syncAttachWebView")
        } else {
            containerView.pinHostedWebView(webView)
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        let hostBoundsReady = hasFiniteHostBounds && hostBounds.width > 1 && hostBounds.height > 1
        if !hostBoundsReady {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.sync.defer container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) " +
                "reason=hostBoundsNotReady host=\(browserPortalDebugFrame(hostBounds)) " +
                "anchor=\(browserPortalDebugFrame(frameInHost)) visibleInUI=\(entry.visibleInUI ? 1 : 0)"
            )
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !containerView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forWebViewId: webViewId,
                        entry: &entry,
                        webView: webView,
                        reason: "hostBoundsNotReady"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    cmuxDebugLog(
                        "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                        "reason=hostBoundsNotReady frame=\(browserPortalDebugFrame(containerView.frame))"
                    )
#endif
                    containerView.setPaneDropContext(nil)
                    containerView.setPortalDragDropZone(nil)
                    containerView.setDropZoneOverlay(zone: nil)
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
            }
            hideContainerView(reason: "hostBoundsNotReady")
            if entry.visibleInUI {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forWebViewId: webViewId,
                    entry: &entry,
                    webView: webView,
                    reason: "hostBoundsNotReady"
                )
            } else {
                scheduleDeferredFullSynchronizeAll()
            }
            containerView.setPaneTopChromeHeight(0)
            return
        }
        let oldFrame = containerView.frame
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        let clampedFrame = frameInHost.intersection(hostBounds)
        let hasVisibleIntersection =
            !clampedFrame.isNull &&
            clampedFrame.width > 1 &&
            clampedFrame.height > 1
        let targetFrame = hasVisibleIntersection ? clampedFrame : frameInHost
        let anchorHidden = Self.isHiddenOrAncestorHidden(anchorView)
        let tinyFrame = targetFrame.width <= 1 || targetFrame.height <= 1
        let outsideHostBounds = !hasVisibleIntersection
        let shouldHide =
            !entry.visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        let transientRecoveryReason: String? = {
            guard entry.visibleInUI else { return nil }
            if anchorHidden { return "anchorHidden" }
            if !hasFiniteFrame { return "nonFiniteFrame" }
            if outsideHostBounds { return "outsideHostBounds" }
            if tinyFrame { return "tinyFrame" }
            return nil
        }()
        let didScheduleTransientRecovery: Bool = {
            guard let transientRecoveryReason else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forWebViewId: webViewId,
                entry: &entry,
                webView: webView,
                reason: transientRecoveryReason
            )
        }()
        let shouldPreserveVisibleOnTransientGeometry =
            didScheduleTransientRecovery &&
            shouldHide &&
            entry.visibleInUI &&
            !containerView.isHidden
        let recoveredFromTransientGeometry =
            previousTransientRecoveryReason != nil &&
            transientRecoveryReason == nil &&
            !shouldHide
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !Self.rectApproximatelyEqual(frameInHost, targetFrame)
        if frameWasClamped {
            cmuxDebugLog(
                "browser.portal.frame.clamp container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "raw=\(browserPortalDebugFrame(frameInHost)) clamped=\(browserPortalDebugFrame(targetFrame)) " +
                "host=\(browserPortalDebugFrame(hostBounds))"
            )
        }
        let collapsedToTiny = oldFrame.width > 1 && oldFrame.height > 1 && tinyFrame
        let restoredFromTiny = (oldFrame.width <= 1 || oldFrame.height <= 1) && !tinyFrame
        if collapsedToTiny {
            cmuxDebugLog(
                "browser.portal.frame.collapse container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "old=\(browserPortalDebugFrame(oldFrame)) new=\(browserPortalDebugFrame(targetFrame))"
            )
        } else if restoredFromTiny {
            cmuxDebugLog(
                "browser.portal.frame.restore container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) anchor=\(browserPortalDebugToken(anchorView)) " +
                "old=\(browserPortalDebugFrame(oldFrame)) new=\(browserPortalDebugFrame(targetFrame))"
            )
        }
#endif
        if shouldPreserveVisibleOnTransientGeometry {
            let hasExistingVisibleFrame =
                oldFrame.width > 1 &&
                oldFrame.height > 1 &&
                containerView.bounds.width > 1 &&
                containerView.bounds.height > 1
#if DEBUG
            cmuxDebugLog(
                "browser.portal.hidden.deferKeep web=\(browserPortalDebugToken(webView)) " +
                "reason=\(transientRecoveryReason ?? "unknown") frame=\(browserPortalDebugFrame(containerView.frame)) " +
                "keepFrame=\(hasExistingVisibleFrame ? 1 : 0)"
            )
#endif
            if hasExistingVisibleFrame {
                containerView.setDropZoneOverlay(zone: nil)
                containerView.setPaneDropContext(nil)
                containerView.setPortalDragDropZone(nil)
                return
            }
        }
        if !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView.frame = targetFrame
            CATransaction.commit()
            refreshReasons.append("frame")
        }

        let expectedContainerBounds = NSRect(origin: .zero, size: targetFrame.size)
        if !Self.rectApproximatelyEqual(containerView.bounds, expectedContainerBounds) {
            let oldContainerBounds = containerView.bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView.bounds = expectedContainerBounds
            CATransaction.commit()
#if DEBUG
            cmuxDebugLog(
                "browser.portal.bounds.normalize container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) old=\(browserPortalDebugFrame(oldContainerBounds)) " +
                "target=\(browserPortalDebugFrame(expectedContainerBounds))"
            )
#endif
            refreshReasons.append("bounds")
        }

        let containerOwnsWebView = webView.superview === containerView
        let containerBounds = containerView.bounds
        let preNormalizeWebFrame = containerOwnsWebView ? webView.frame : .zero
        let inspectorHeightFromInsets = max(0, containerBounds.height - preNormalizeWebFrame.height)
        let inspectorHeightFromOverflow = max(0, preNormalizeWebFrame.maxY - containerBounds.maxY)
        let inspectorHeightApprox = max(inspectorHeightFromInsets, inspectorHeightFromOverflow)
#if DEBUG
        let inspectorSubviews = Self.inspectorSubviewCount(in: containerView)
#endif
        if containerOwnsWebView,
           let repairedBottomDockFrame = Self.repairedBottomDockedPageFrame(
               in: containerView,
               primaryWebView: webView
           ) {
            let oldWebFrame = preNormalizeWebFrame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            webView.frame = repairedBottomDockFrame
            CATransaction.commit()
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webframe.bottomDockRepair web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) old=\(browserPortalDebugFrame(oldWebFrame)) " +
                "new=\(browserPortalDebugFrame(repairedBottomDockFrame)) bounds=\(browserPortalDebugFrame(containerBounds)) " +
                "inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) " +
                "inspectorInsets=\(String(format: "%.1f", inspectorHeightFromInsets)) " +
                "inspectorOverflow=\(String(format: "%.1f", inspectorHeightFromOverflow)) " +
                "inspectorSubviews=\(inspectorSubviews) " +
                "source=\(source)"
            )
#endif
            refreshReasons.append("webFrameBottomDock")
        } else if containerOwnsWebView && Self.frameExtendsOutsideBounds(preNormalizeWebFrame, bounds: containerBounds) {
            let oldWebFrame = preNormalizeWebFrame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            webView.frame = containerBounds
            CATransaction.commit()
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webframe.normalize web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) old=\(browserPortalDebugFrame(oldWebFrame)) " +
                "new=\(browserPortalDebugFrame(webView.frame)) bounds=\(browserPortalDebugFrame(containerBounds)) " +
                "inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) " +
                "inspectorInsets=\(String(format: "%.1f", inspectorHeightFromInsets)) " +
                "inspectorOverflow=\(String(format: "%.1f", inspectorHeightFromOverflow)) " +
                "inspectorSubviews=\(inspectorSubviews) " +
                "source=\(source)"
            )
#endif
            refreshReasons.append("webFrame")
        }

        let revealedForDisplay = !shouldHide && containerView.isHidden
        if shouldHide, !containerView.isHidden, !shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) value=\(shouldHide ? 1 : 0) " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                    "outside=\(outsideHostBounds ? 1 : 0) frame=\(browserPortalDebugFrame(targetFrame)) " +
                    "host=\(browserPortalDebugFrame(hostBounds))"
            )
#endif
            hideContainerView(reason: transientRecoveryReason ?? "geometryHidden")
        } else if !shouldHide, containerView.isHidden {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.hidden container=\(browserPortalDebugToken(containerView)) " +
                "web=\(browserPortalDebugToken(webView)) value=0 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(browserPortalDebugFrame(targetFrame)) " +
                "host=\(browserPortalDebugFrame(hostBounds))"
            )
#endif
            containerView.isHidden = false
        }
        containerView.setPaneTopChromeHeight(shouldHide ? 0 : entry.paneTopChromeHeight)
        containerView.setSearchOverlay(shouldHide ? nil : entry.searchOverlay)
        containerView.setOmnibarSuggestions(shouldHide ? nil : entry.omnibarSuggestions)
        containerView.setPaneDropContext(containerView.isHidden ? nil : entry.paneDropContext)
        containerView.setDropZoneOverlay(zone: containerView.isHidden ? nil : entry.dropZone)
        if revealedForDisplay {
            refreshReasons.append("reveal")
        }
        if recoveredFromTransientGeometry {
            // Drag/reparent churn can recover to the same visible frame we preserved.
            // Force a redraw so WebKit doesn't keep stale tiles until a later resize/focus.
            refreshReasons.append("transientRecovery")
        }
        if forcePresentationRefresh {
            refreshReasons.append("anchor")
        }
        if transientRecoveryReason == nil {
            resetTransientRecoveryRetryIfNeeded(forWebViewId: webViewId, entry: &entry)
        }
        let hostedInspectorAdjustedDuringSync =
            containerOwnsWebView &&
            hostView.reapplyHostedInspectorDividerIfNeeded(in: containerView, reason: "portal.sync")
        let requiresRenderingStateReattach = webView.browserPortalRequiresRenderingStateReattach
        let presentationUpdateKind = HostedWebViewPresentationUpdateKind.resolve(
            reasons: refreshReasons
        )
        let shouldReapplyHostedInspectorPostRefresh =
            presentationUpdateKind == .refresh && requiresRenderingStateReattach
        if !shouldHide, containerOwnsWebView, presentationUpdateKind != .none {
            if presentationUpdateKind == .refresh &&
                hostedInspectorAdjustedDuringSync &&
                !recoveredFromTransientGeometry &&
                !requiresRenderingStateReattach {
#if DEBUG
                cmuxDebugLog(
                    "browser.portal.refresh.skip web=\(browserPortalDebugToken(webView)) " +
                    "container=\(browserPortalDebugToken(containerView)) reason=\(source):" +
                    "\(refreshReasons.joined(separator: ",")) adjustedDuringSync=1"
                )
#endif
            } else {
                let refreshReason = "\(source):" + refreshReasons.joined(separator: ",")
                switch presentationUpdateKind {
                case .none:
                    break
                case .geometryOnly:
                    invalidateHostedWebViewGeometry(
                        webView,
                        in: containerView,
                        reason: refreshReason
                    )
                case .refresh:
                    refreshHostedWebViewPresentation(
                        webView,
                        in: containerView,
                        reason: refreshReason
                    )
                }
            }
        }
        if containerOwnsWebView,
           (!hostedInspectorAdjustedDuringSync || shouldReapplyHostedInspectorPostRefresh) {
            // Keep the existing post-sync pass for cases where the inspector candidate
            // appears only after WebKit settles. Re-run it after rendering-state reattach
            // refreshes as well, because WebKit's enter/unhide relayout can overwrite the
            // preferred divider position we already clamped during portal.sync.
            _ = hostView.reapplyHostedInspectorDividerIfNeeded(in: containerView, reason: "portal.sync.postRefresh")
        }
#if DEBUG
        cmuxDebugLog(
            "browser.portal.sync.result web=\(browserPortalDebugToken(webView)) source=\(source) " +
            "container=\(browserPortalDebugToken(containerView)) " +
            "anchor=\(browserPortalDebugToken(anchorView)) host=\(browserPortalDebugToken(hostView)) " +
            "hostWin=\(hostView.window?.windowNumber ?? -1) " +
            "old=\(browserPortalDebugFrame(oldFrame)) raw=\(browserPortalDebugFrame(frameInHost)) " +
            "target=\(browserPortalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
            "entryVisible=\(entry.visibleInUI ? 1 : 0) " +
            "containerOwnsWeb=\(containerOwnsWebView ? 1 : 0) " +
            "inspectorAdjusted=\(hostedInspectorAdjustedDuringSync ? 1 : 0) " +
            "containerHidden=\(containerView.isHidden ? 1 : 0) webHidden=\(webView.isHidden ? 1 : 0) " +
            "containerBounds=\(browserPortalDebugFrame(containerView.bounds)) " +
            "preWebFrame=\(browserPortalDebugFrame(preNormalizeWebFrame)) " +
            "webFrame=\(browserPortalDebugFrame(webView.frame)) webBounds=\(browserPortalDebugFrame(webView.bounds)) " +
            "inspectorHApprox=\(String(format: "%.1f", inspectorHeightApprox)) " +
            "inspectorInsets=\(String(format: "%.1f", inspectorHeightFromInsets)) " +
            "inspectorOverflow=\(String(format: "%.1f", inspectorHeightFromOverflow)) " +
            "inspectorSubviews=\(inspectorSubviews)"
        )
#endif
    }

}
