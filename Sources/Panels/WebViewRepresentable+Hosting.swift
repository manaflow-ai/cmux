import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Portal & Inline Hosting Updates
extension WebViewRepresentable {
    static func clearPortalCallbacks(for host: NSView) {
        guard let host = host as? HostContainerView else { return }
        host.onDidMoveToWindow = nil
        host.onGeometryChanged = nil
        host.clearLocalInlineCallbacks()
    }

    private static func shouldPreserveExternalFullscreenHost(
        for webView: WKWebView,
        relativeTo expectedWindow: NSWindow?
    ) -> Bool {
        webView.cmuxIsManagedByExternalFullscreenWindow(relativeTo: expectedWindow)
    }

    private static func localInlineTransferRoot(for webView: WKWebView) -> NSView? {
        var current = webView.superview
        var last: NSView?
        while let view = current {
            if view is WindowBrowserSlotView {
                return view
            }
            if view is HostContainerView {
                break
            }
            last = view
            current = view.superview
        }
        return last ?? webView.superview
    }

    private static func directTransferChild(of container: NSView, containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== container {
            directChild = view
            current = view.superview
        }
        guard current === container else { return nil }
        return directChild
    }

    private static func relatedWebKitTransferSubviews(
        from sourceSuperview: NSView,
        primaryWebView: WKWebView
    ) -> [NSView] {
        var relatedSubviews: [NSView] = []
        var seen = Set<ObjectIdentifier>()
        let inspectorFrontend = primaryWebView.cmuxInspectorFrontendWebView()

        func append(_ candidate: NSView?) {
            guard let candidate, candidate !== sourceSuperview else { return }
            let id = ObjectIdentifier(candidate)
            guard seen.insert(id).inserted else { return }
            relatedSubviews.append(candidate)
        }

        func containsInspectorFrontend(_ candidate: NSView) -> Bool {
            guard let inspectorFrontend else { return false }
            return candidate === inspectorFrontend || inspectorFrontend.isDescendant(of: candidate)
        }

        if let directChild = directTransferChild(of: sourceSuperview, containing: primaryWebView),
           !containsInspectorFrontend(directChild) {
            append(directChild)
        } else {
            append(primaryWebView)
        }

        for view in sourceSuperview.subviews {
            if view === primaryWebView { continue }
            let className = String(describing: type(of: view))
            if containsInspectorFrontend(view) {
#if DEBUG
                cmuxDebugLog(
                    "browser.localHost.reparent.skipInspectorFrontend " +
                    "view=\(Self.objectID(view)) class=\(className)"
                )
#endif
                continue
            }
            if cmuxIsWebInspectorClassName(className) || cmuxIsWebInspectorObject(view) {
                continue
            }
            guard className.contains("WK") else { continue }
            append(view)
        }

        return relatedSubviews
    }

    private static func moveWebKitRelatedSubviewsIntoHostIfNeeded(
        from sourceSuperview: NSView,
        to container: WindowBrowserSlotView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        let relatedSubviews = relatedWebKitTransferSubviews(
            from: sourceSuperview,
            primaryWebView: primaryWebView
        )
        guard !relatedSubviews.isEmpty else { return }
        let preserveSlotLocalFrames = sourceSuperview is WindowBrowserSlotView
        let sourceSlotBoundsSize = sourceSuperview.bounds.size
        var movedSubviewCount = 0
        var reusedSourceLocalFrames = false
#if DEBUG
        cmuxDebugLog(
            "browser.localHost.reparent.batch reason=\(reason) source=\(Self.objectID(sourceSuperview)) " +
            "container=\(Self.objectID(container)) count=\(relatedSubviews.count) " +
            "sourceType=\(String(describing: type(of: sourceSuperview))) targetType=\(String(describing: type(of: container)))"
        )
#endif
        for view in relatedSubviews {
            if view === container || view.isDescendant(of: container) {
                continue
            }
            let className = String(describing: type(of: view))
            let targetFrame: NSRect
            let currentSuperview = view.superview
            if preserveSlotLocalFrames && currentSuperview === sourceSuperview {
                targetFrame = view.frame
                reusedSourceLocalFrames = true
            } else {
                let frameInWindow = currentSuperview?.convert(view.frame, to: nil)
                    ?? sourceSuperview.convert(view.frame, to: nil)
                targetFrame = container.convert(frameInWindow, from: nil)
            }
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = targetFrame
            movedSubviewCount += 1
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.reparent.batch.item reason=\(reason) class=\(className) " +
                "view=\(Self.objectID(view))"
            )
#endif
        }
        guard movedSubviewCount > 0 else { return }
        if reusedSourceLocalFrames, sourceSlotBoundsSize != container.bounds.size {
            container.resizeSubviews(withOldSize: sourceSlotBoundsSize)
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
    }

    private static func installPortalAnchorView(_ anchorView: NSView, in host: NSView) {
        // SwiftUI can keep transient replacement hosts alive off-window during split
        // reparenting. Never let those hosts steal the shared portal anchor, or the
        // portal will bind against an anchor with no real window and WKWebView will
        // fall into a hidden/unrendered state.
        guard host.window != nil else { return }
        if anchorView.superview !== host {
            anchorView.removeFromSuperview()
            anchorView.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(anchorView)
            NSLayoutConstraint.activate([
                anchorView.topAnchor.constraint(equalTo: host.topAnchor),
                anchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                anchorView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                anchorView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        } else if anchorView.translatesAutoresizingMaskIntoConstraints {
            anchorView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                anchorView.topAnchor.constraint(equalTo: host.topAnchor),
                anchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                anchorView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                anchorView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
        host.layoutSubtreeIfNeeded()
    }

    private func schedulePortalLifecycleVisibilityUpdate(
        coordinator: Coordinator,
        generation: Int,
        visibleInUI: Bool,
        reason: String,
        requireDesiredVisibilityMatch: Bool = true
    ) {
        let browserPanel = panel
        Task { @MainActor [weak coordinator] in
            guard let coordinator else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard !requireDesiredVisibilityMatch ||
                coordinator.desiredPortalVisibleInUI == visibleInUI else { return }
            browserPanel.noteWebViewVisibility(visibleInUI, reason: reason)
        }
    }

    private func updateUsingLocalInlineHosting(_ nsView: NSView, context: Context, webView: WKWebView) -> Bool {
        guard let host = nsView as? HostContainerView else { return false }
        let slotView = host.ensureLocalInlineSlotView()
        let isAlreadyInLocalHost = host.containsManagedLocalInlineContent(webView)
        let shouldPreserveExternalFullscreenHost = Self.shouldPreserveExternalFullscreenHost(
            for: webView,
            relativeTo: host.window
        )
        let didAttachWebViewToLocalHost =
            !isAlreadyInLocalHost && !shouldPreserveExternalFullscreenHost

        let coordinator = context.coordinator
        coordinator.desiredPortalVisibleInUI = false
        coordinator.desiredPortalZPriority = 0
        coordinator.attachGeneration += 1

        if panel.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(host),
            reason: "localInlineHosting"
        ) {
            BrowserWindowPortalRegistry.discard(
                webView: webView,
                source: "viewStateChanged.localInlineHosting",
                preserveCurrentSuperview: true
            )
        }

        let shouldPreserveExistingExternalLocalHost =
            host.window == nil &&
            webView.superview != nil &&
            !host.containsManagedLocalInlineContent(webView)
        if shouldPreserveExistingExternalLocalHost {
            // Split zoom can instantiate a replacement local host before it joins a window.
            // Never let that off-window host steal the live page + inspector hierarchy away
            // from the currently visible local host.
            host.setLocalInlineSlotHidden(true)
            coordinator.lastPortalHostId = nil
            coordinator.lastSynchronizedHostGeometryRevision = 0
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.reparent.skip web=\(Self.objectID(webView)) " +
                "reason=offWindowReplacementHost super=\(Self.objectID(webView.superview)) " +
                "host=\(Self.objectID(host)) slot=\(Self.objectID(slotView))"
            )
            Self.logDevToolsState(
                panel,
                event: "localHost.skip",
                generation: coordinator.attachGeneration,
                retryCount: 0,
                details: Self.attachContext(webView: webView, host: host)
            )
#endif
            return false
        }

#if DEBUG
        if shouldPreserveExternalFullscreenHost {
            cmuxDebugLog(
                "browser.localHost.reparent.skip web=\(Self.objectID(webView)) " +
                "reason=fullscreenExternalHost host=\(Self.objectID(host)) " +
                "slot=\(Self.objectID(slotView)) state=\(String(describing: webView.fullscreenState))"
            )
        }
#endif

        let preferredAttachedWidthState = panel.preferredAttachedDeveloperToolsWidthState()
        host.setPreferredHostedInspectorWidth(
            width: preferredAttachedWidthState.width,
            widthFraction: preferredAttachedWidthState.widthFraction
        )
        host.setHostedInspectorFrontendWebView(webView.cmuxInspectorFrontendWebView())
        host.onPreferredHostedInspectorWidthChanged = { [weak browserPanel = panel] width, _ in
            guard let browserPanel else { return }
            browserPanel.recordPreferredAttachedDeveloperToolsWidth(
                width,
                containerBounds: slotView.bounds
            )
        }
        slotView.onHostedInspectorLayout = { [weak host] _ in
            host?.scheduleHostedInspectorDividerReapply(reason: "slot.layout")
            host?.scheduleHostedInspectorDockConfigurationSync(reason: "slot.layout")
        }

        if didAttachWebViewToLocalHost {
            if let sourceSuperview = Self.localInlineTransferRoot(for: webView) {
                Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                    from: sourceSuperview,
                    to: slotView,
                    primaryWebView: webView,
                    reason: "attachLocalHost"
                )
            } else {
                slotView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
        }

        slotView.isHidden = false
        host.pinHostedWebView(
            webView,
            in: host.currentHostedWebViewContainer(preferredSlotView: slotView)
        )
        // Local-inline hosting takes ownership of the live WKWebView hierarchy.
        // Drop any stale portal entry once local-inline hosting owns the live
        // WKWebView hierarchy so deferred portal recovery cannot mutate the
        // browser after workspace switches.
        BrowserWindowPortalRegistry.discard(
            webView: webView,
            source: "viewStateChanged.localInlineHosting",
            preserveCurrentSuperview: true
        )
        coordinator.lastPortalHostId = nil
        coordinator.lastSynchronizedHostGeometryRevision = 0
        if host.window != nil && !shouldPreserveExternalFullscreenHost {
            let wasDeveloperToolsVisible = panel.isDeveloperToolsVisible()
            panel.noteDeveloperToolsHostAttached()
            panel.restoreDeveloperToolsAfterAttachIfNeeded()
            if let sourceSuperview = Self.localInlineTransferRoot(for: webView),
               didAttachWebViewToLocalHost || sourceSuperview === slotView {
                Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                    from: sourceSuperview,
                    to: slotView,
                    primaryWebView: webView,
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.reconcile.immediate"
                        : "localInline.reconcile.existingHost"
                )
            }
            host.setHostedInspectorFrontendWebView(webView.cmuxInspectorFrontendWebView())
            let didRevealDeveloperToolsAfterAttach =
                !wasDeveloperToolsVisible && panel.isDeveloperToolsVisible()
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
            slotView.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.refreshHostedWebKitPresentation(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.immediate"
                    : "localInline.update.existingHost",
                forceLifecycleRefresh: didRevealDeveloperToolsAfterAttach
            )
            host.normalizeHostedInspectorLayoutIfNeeded(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.immediate"
                    : "localInline.update.existingHost"
            )
            host.scheduleHostedInspectorDividerReapply(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.sync"
                    : "localInline.update.existingHost"
            )
            DispatchQueue.main.async { [weak host, weak webView] in
                guard let host, let webView else { return }
                if let sourceSuperview = Self.localInlineTransferRoot(for: webView),
                   sourceSuperview === slotView {
                    Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                        from: sourceSuperview,
                        to: slotView,
                        primaryWebView: webView,
                        reason: "localInline.reconcile.async"
                    )
                }
                host.setHostedInspectorFrontendWebView(webView.cmuxInspectorFrontendWebView())
                host.refreshHostedWebKitPresentation(
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.update.async"
                        : "localInline.update.existingHost.async",
                    forceLifecycleRefresh: didRevealDeveloperToolsAfterAttach
                )
                host.scheduleHostedInspectorDockConfigurationSync(
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.update.async"
                        : "localInline.update.existingHost.async"
                )
            }
        } else if !shouldPreserveExternalFullscreenHost {
            panel.consumeAttachedDeveloperToolsManualCloseIfNeeded()
            host.scheduleHostedInspectorDockConfigurationSync(reason: "localInline.update")
        }

#if DEBUG
        Self.logDevToolsState(
            panel,
            event: "localHost.update",
            generation: coordinator.attachGeneration,
            retryCount: 0,
            details: Self.attachContext(webView: webView, host: host)
        )
#endif
        return !shouldPreserveExternalFullscreenHost
    }

    private func updateUsingWindowPortal(_ nsView: NSView, context: Context, webView: WKWebView) -> Bool {
        guard let host = nsView as? HostContainerView else { return false }
        if panel.shouldUseLocalInlineDeveloperToolsHosting() {
            host.clearStaleHostedInspectorOwnershipState()
            host.releaseHostedWebViewConstraints()
            let hostId = ObjectIdentifier(host)
            if panel.releasePortalHostIfOwned(
                hostId: hostId,
                reason: "windowPortalSuppressedForLocalInlineHosting"
            ) {
                BrowserWindowPortalRegistry.discard(
                    webView: webView,
                    source: "viewStateChanged.windowPortalSuppressedForLocalInlineHosting",
                    preserveCurrentSuperview: true
                )
            }
            return false
        }
        host.prepareForWindowPortalHosting()
        host.setLocalInlineSlotHidden(true)
        host.releaseHostedWebViewConstraints()
        let shouldPreserveExternalFullscreenHost = Self.shouldPreserveExternalFullscreenHost(
            for: webView,
            relativeTo: host.window
        )

        let coordinator = context.coordinator
        let paneDropContext = currentPaneDropContext()
        let isCurrentPaneOwner = paneDropContext?.paneId.id == paneId.id
        let hostId = ObjectIdentifier(host)
        let previousVisible = coordinator.desiredPortalVisibleInUI
        let previousZPriority = coordinator.desiredPortalZPriority
        coordinator.desiredPortalVisibleInUI = shouldAttachWebView && isCurrentPaneOwner
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration
        let activePaneDropContext = coordinator.desiredPortalVisibleInUI ? paneDropContext : nil
        let activeSearchOverlay = coordinator.desiredPortalVisibleInUI ? searchOverlay : nil
        let portalAnchorView = panel.portalAnchorView
        let portalHideReason = !isCurrentPaneOwner ? "lostPaneOwnership" : "hidden"
        let didReleasePortalHost: Bool
        if !shouldAttachWebView || !isCurrentPaneOwner {
            didReleasePortalHost = panel.releasePortalHostIfOwned(
                hostId: hostId,
                reason: portalHideReason
            )
            // Only the host that currently owns the portal is allowed to hide it.
            // Older keep-alive hosts can still receive updates after a new owner binds.
            if didReleasePortalHost {
                BrowserWindowPortalRegistry.hide(
                    webView: webView,
                    source: "viewStateChanged.\(portalHideReason)"
                )
            }
        } else {
            didReleasePortalHost = false
        }
        let portalHostAccepted =
            shouldAttachWebView &&
            isCurrentPaneOwner &&
            panel.claimPortalHost(
                hostId: hostId,
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "update"
            )
        if portalHostAccepted || didReleasePortalHost {
            let lifecycleVisibleInUI = portalHostAccepted && coordinator.desiredPortalVisibleInUI
            let lifecycleReason = lifecycleVisibleInUI ? "portal.update.visible" : "portal.update.hidden"
            schedulePortalLifecycleVisibilityUpdate(
                coordinator: coordinator,
                generation: generation,
                visibleInUI: lifecycleVisibleInUI,
                reason: lifecycleReason,
                requireDesiredVisibilityMatch: portalHostAccepted
            )
        }
#if DEBUG
        if !isCurrentPaneOwner && (shouldAttachWebView || host.window != nil) {
            cmuxDebugLog(
                "browser.portal.owner.skip panel=\(panel.id.uuidString.prefix(5)) " +
                "viewPane=\(paneId.id.uuidString.prefix(5)) " +
                "currentPane=\(paneDropContext?.paneId.id.uuidString.prefix(5) ?? "nil") " +
                "host=\(Self.objectID(host)) hostInWin=\(host.window != nil ? 1 : 0) " +
                "released=\(didReleasePortalHost ? 1 : 0)"
            )
        }
#endif
        if host.window != nil, portalHostAccepted {
            Self.installPortalAnchorView(portalAnchorView, in: host)
        }
        let activeOmnibarSuggestions = coordinator.desiredPortalVisibleInUI ? omnibarSuggestions : nil

        host.onDidMoveToWindow = { [weak host, weak webView, weak coordinator, weak portalAnchorView, weak browserPanel = panel] in
            guard let host, let webView, let coordinator, let portalAnchorView, let browserPanel else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard currentPaneDropContext()?.paneId.id == paneId.id else { return }
            guard browserPanel.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "didMoveToWindow"
            ) else { return }
            guard host.window != nil else { return }
            Self.installPortalAnchorView(portalAnchorView, in: host)
            BrowserWindowPortalRegistry.bind(
                webView: webView,
                to: portalAnchorView,
                visibleInUI: coordinator.desiredPortalVisibleInUI,
                zPriority: coordinator.desiredPortalZPriority
            )
            BrowserWindowPortalRegistry.refresh(
                webView: webView,
                reason: "portalHostBind.didMoveToWindow"
            )
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: activePaneDropContext)
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
            coordinator.lastPortalHostId = ObjectIdentifier(host)
            coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
        }
        host.onGeometryChanged = { [weak host, weak webView, weak coordinator, weak portalAnchorView, weak browserPanel = panel] in
            guard let host, let webView, let coordinator, let portalAnchorView, let browserPanel else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard currentPaneDropContext()?.paneId.id == paneId.id else { return }
            guard browserPanel.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "geometryChanged"
            ) else { return }
            guard host.window != nil else { return }
            let hostId = ObjectIdentifier(host)
            Self.installPortalAnchorView(portalAnchorView, in: host)
            if coordinator.lastPortalHostId != hostId ||
               !BrowserWindowPortalRegistry.isWebView(webView, boundTo: portalAnchorView) {
                BrowserWindowPortalRegistry.bind(
                    webView: webView,
                    to: portalAnchorView,
                    visibleInUI: coordinator.desiredPortalVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "portalHostBind.geometryChanged"
                )
                BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                    for: webView,
                    height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
                )
                BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: activePaneDropContext)
                BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
                BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
                coordinator.lastPortalHostId = hostId
            }
            BrowserWindowPortalRegistry.synchronizeForAnchor(portalAnchorView)
            coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
        }

        if !shouldAttachWebView {
            // In portal mode we no longer detach/re-attach to preserve DevTools state.
            // Sync the inspector preference directly so manual closes are respected.
            panel.syncDeveloperToolsPreferenceFromInspector(
                preserveVisibleIntent: panel.shouldPreserveDeveloperToolsIntentWhileDetached()
            )
        }

        if host.window != nil, portalHostAccepted {
            let geometryRevision = host.geometryRevision
            let portalEntryMissing = !BrowserWindowPortalRegistry.isWebView(webView, boundTo: portalAnchorView)
            let shouldBindNow =
                coordinator.lastPortalHostId != hostId ||
                webView.superview == nil ||
                portalEntryMissing ||
                previousVisible != shouldAttachWebView ||
                previousZPriority != portalZPriority
            if shouldBindNow {
                Self.installPortalAnchorView(portalAnchorView, in: host)
                BrowserWindowPortalRegistry.bind(
                    webView: webView,
                    to: portalAnchorView,
                    visibleInUI: coordinator.desiredPortalVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                // Force a rendering-state reattach after portal host replacement
                // (e.g. after a pane split). Without this, WKWebView can freeze
                // because _exitInWindow/_enterInWindow are never cycled when the
                // web view is reparented to a new container during bind.
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "portalHostBind"
                )
                coordinator.lastPortalHostId = hostId
                coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
            }
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
            if !shouldBindNow,
               coordinator.lastSynchronizedHostGeometryRevision != geometryRevision {
                BrowserWindowPortalRegistry.synchronizeForAnchor(portalAnchorView)
                coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
            }
        } else if portalHostAccepted {
            // Bind is deferred until host moves into a window. Keep the current
            // portal entry's desired state in sync so stale callbacks cannot keep
            // the previous anchor visible while this host is temporarily off-window.
            BrowserWindowPortalRegistry.updateEntryVisibility(
                for: webView,
                visibleInUI: coordinator.desiredPortalVisibleInUI,
                zPriority: coordinator.desiredPortalZPriority
            )
        }

        if portalHostAccepted {
            BrowserWindowPortalRegistry.updateDropZoneOverlay(
                for: webView,
                zone: coordinator.desiredPortalVisibleInUI ? paneDropZone : nil
            )
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(
                for: webView,
                context: activePaneDropContext
            )
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
        }

        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        #if DEBUG
        Self.logDevToolsState(
            panel,
            event: "portal.update",
            generation: coordinator.attachGeneration,
            retryCount: 0,
            details: Self.attachContext(webView: webView, host: host)
        )
        #endif
        return portalHostAccepted && !shouldPreserveExternalFullscreenHost
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = panel.webView
        let coordinator = context.coordinator
        let isCurrentPaneOwner = currentPaneDropContext()?.paneId.id == paneId.id
        if let previousWebView = coordinator.webView, previousWebView !== webView {
            BrowserWindowPortalRegistry.detach(webView: previousWebView)
            coordinator.lastPortalHostId = nil
            coordinator.lastSynchronizedHostGeometryRevision = 0
        }
        coordinator.panel = panel
        coordinator.webView = webView

        Self.clearPortalCallbacks(for: nsView)
        let hostOwnsPortal = useLocalInlineHosting
            ? updateUsingLocalInlineHosting(nsView, context: context, webView: webView)
            : updateUsingWindowPortal(nsView, context: context, webView: webView)
        if hostOwnsPortal {
            panel.releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: "representable.update")
        }
        Self.applyWebViewFirstResponderPolicy(
            panel: panel,
            webView: webView,
            isPanelFocused: isPanelFocused && isCurrentPaneOwner && hostOwnsPortal
        )

        Self.applyFocus(
            panel: panel,
            webView: webView,
            nsView: nsView,
            shouldFocusWebView: shouldFocusWebView && isCurrentPaneOwner && hostOwnsPortal,
            isPanelFocused: isPanelFocused && isCurrentPaneOwner && hostOwnsPortal
        )
    }

}
