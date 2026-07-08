import AppKit

@MainActor
extension BrowserPanel {
    func detachedDeveloperToolsWindowsForPanel() -> [NSWindow] {
        NSApp.windows.filter { ($0.isVisible || $0.isMiniaturized) && detachedDeveloperToolsWindowBelongsToPanel($0) }
    }

    var hasPendingDetachedDeveloperToolsWindowCloseResolution: Bool {
        detachedDeveloperToolsWindowCloseResolutionTimer != nil
    }
    func clearDeveloperToolsVisibleIntentForHiddenState() {
        developerToolsDetachedOpenGraceDeadline = nil
        developerToolsLastKnownVisibleAt = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        developerToolsPreservedVisibleIntentForNextAttach = false
        setPreferredDeveloperToolsVisible(false)
        cancelDeveloperToolsRestoreRetry()
    }

    func cancelDetachedDeveloperToolsWindowCloseResolution() {
        detachedDeveloperToolsWindowCloseResolutionTimer?.cancel()
        detachedDeveloperToolsWindowCloseResolutionTimer = nil
        detachedDeveloperToolsWindowCloseResolutionGeneration &+= 1
    }

    func cancelDetachedDeveloperToolsWindowDismissal() {
        for task in detachedDeveloperToolsWindowDismissalTasks {
            task.cancel()
        }
        detachedDeveloperToolsWindowDismissalTasks.removeAll()
    }

    func scheduleDeveloperToolsDockControlNormalization(
        reason: String,
        delay: TimeInterval = 0
    ) {
        developerToolsDockControlNormalizationTask?.cancel()
        developerToolsDockControlNormalizationTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await ContinuousClock().sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.developerToolsDockControlNormalizationTask = nil
            self.normalizeDeveloperToolsDockControls()
#if DEBUG
            cmuxDebugLog(
                "browser.devtools dockControls.normalize panel=\(self.id.uuidString.prefix(5)) " +
                "reason=\(reason) \(self.debugDeveloperToolsStateSummary()) \(self.debugDeveloperToolsGeometrySummary())"
            )
#endif
        }
    }
    func installDetachedDeveloperToolsWindowCloseObserver() {
        guard detachedDeveloperToolsWindowCloseObserver == nil else { return }
        detachedDeveloperToolsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow else { return }
            guard Thread.isMainThread else { return }
            let handledDetachedInspector = MainActor.assumeIsolated {
                return self.handleDetachedDeveloperToolsWindowWillClose(window)
            }
            _ = handledDetachedInspector
        }
    }

    @discardableResult
    func handleDetachedDeveloperToolsWindowWillClose(_ window: NSWindow) -> Bool {
        guard detachedDeveloperToolsWindowBelongsToPanel(window) else { return false }
        if detachedDeveloperToolsExplicitUserCloseWindowIds.remove(ObjectIdentifier(window)) != nil {
#if DEBUG
            cmuxDebugLog(
                "browser.devtools detachedClose.userWillClose panel=\(id.uuidString.prefix(5)) " +
                "window=\(window.windowNumber) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
            )
#endif
            return true
        }
        // Explicit user closes are intercepted in AppDelegate before AppKit posts
        // willClose. A raw willClose can also be WebKit's redock path, where
        // closing _inspector here tears down the frontend while attach continues.
        scheduleDetachedDeveloperToolsWindowCloseResolution(source: "willClose")
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.defer panel=\(id.uuidString.prefix(5)) " +
            "window=\(window.windowNumber) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return true
    }

    @discardableResult
    func closeDeveloperToolsFromDetachedInspectorWindowUserAction(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        guard noteDetachedDeveloperToolsWindowClosed(window, source: source) else { return false }
        detachedDeveloperToolsExplicitUserCloseWindowIds.insert(ObjectIdentifier(window))
        window.close()
        scheduleDetachedDeveloperToolsWindowCloseResolution(
            source: "\(source).reconcile",
            allowInspectorTeardown: false
        )
        return true
    }

    func ownsDetachedDeveloperToolsWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible || window.isMiniaturized else { return false }
        return detachedDeveloperToolsWindowBelongsToPanel(window)
    }

    @discardableResult
    func noteDetachedDeveloperToolsWindowClosed(
        _ window: NSWindow,
        source: String
    ) -> Bool {
        guard detachedDeveloperToolsWindowBelongsToPanel(window) else { return false }
        developerToolsTransitionSettleWorkItem?.cancel()
        developerToolsTransitionSettleWorkItem = nil
        pendingDeveloperToolsTransitionTargetVisible = nil
        developerToolsTransitionTargetVisible = nil
        cancelDetachedDeveloperToolsWindowCloseResolution()
        clearDeveloperToolsVisibleIntentForHiddenState()
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.\(source) panel=\(id.uuidString.prefix(5)) " +
            "closed=observed \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        return true
    }

    func scheduleDetachedDeveloperToolsWindowCloseResolution(
        source: String,
        startedAt: Date = Date(),
        allowInspectorTeardown: Bool = true
    ) {
        cancelDetachedDeveloperToolsWindowCloseResolution()
        let generation = detachedDeveloperToolsWindowCloseResolutionGeneration
        let delayNanoseconds = Int(developerToolsAttachedManualCloseDetectionDelay * 1_000_000_000)
        // WebKit exposes no completion callback for re-dock. It closes the
        // detached window before the attached frontend/layout is observable.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .nanoseconds(delayNanoseconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.detachedDeveloperToolsWindowCloseResolutionTimer != nil else { return }
            guard self.detachedDeveloperToolsWindowCloseResolutionGeneration == generation else { return }
            self.detachedDeveloperToolsWindowCloseResolutionTimer?.cancel()
            self.detachedDeveloperToolsWindowCloseResolutionTimer = nil
            self.resolveDetachedDeveloperToolsWindowClose(
                source: source,
                startedAt: startedAt,
                allowInspectorTeardown: allowInspectorTeardown
            )
        }
        detachedDeveloperToolsWindowCloseResolutionTimer = timer
        timer.resume()
    }

    func resolveDetachedDeveloperToolsWindowClose(
        source: String,
        startedAt: Date,
        allowInspectorTeardown: Bool
    ) {
        guard detachedDeveloperToolsWindowsForPanel().isEmpty else { return }
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible() else {
            reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
            return
        }

        let visible = isDeveloperToolsVisible()
        let hasAttachedLayout = hasAttachedDeveloperToolsLayout()
        if hasAttachedLayout {
            guard allowInspectorTeardown else {
                clearDeveloperToolsVisibleIntentForHiddenState()
                reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
                return
            }
            adoptAttachedDeveloperToolsRedock(source: source)
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        // WebKit's attach path is not reflected in cmux's transition flag, so a
        // no-window/no-layout state remains ambiguous until the bounded deadline.
        if (preferredDeveloperToolsVisible || visible),
           elapsed < developerToolsDetachedWindowCloseResolutionMaxDuration {
            scheduleDetachedDeveloperToolsWindowCloseResolution(
                source: "\(source).ambiguous",
                startedAt: startedAt,
                allowInspectorTeardown: allowInspectorTeardown
            )
            return
        }
        let closeReason = visible ? "redockUnsupported" : "manual"
        if visible, allowInspectorTeardown {
            _ = WebViewInspectorTeardown.closeInspector(for: webView)
        }

        clearDeveloperToolsVisibleIntentForHiddenState()
        reevaluateHiddenWebViewDiscardAfterDeveloperToolsHidden()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.\(closeReason) panel=\(id.uuidString.prefix(5)) " +
            "source=\(source) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
    }

    func adoptAttachedDeveloperToolsRedock(source: String) {
        developerToolsDetachedOpenGraceDeadline = nil
        forceDeveloperToolsRefreshOnNextAttach = false
        developerToolsPreservedVisibleIntentForNextAttach = false
        developerToolsLastKnownVisibleAt = Date()
        developerToolsLastAttachedHostAt = Date()
        setPreferredDeveloperToolsPresentation(.attached)
        setPreferredDeveloperToolsVisible(true)
        cancelDeveloperToolsRestoreRetry()
        normalizeDeveloperToolsDockControls()
        scheduleDeveloperToolsDockControlNormalization(
            reason: "redockAdopt.\(source)",
            delay: developerToolsTransitionSettleDelay
        )
        BrowserWindowPortalRegistry.refresh(
            webView: webView,
            reason: "developerToolsRedockAdopt"
        )
        scheduleDeveloperToolsVisibilityLossCheck()
        reevaluateHiddenWebViewDiscardScheduling(reason: "developer_tools_visibility_changed")
#if DEBUG
        cmuxDebugLog(
            "browser.devtools detachedClose.redockAdopt panel=\(id.uuidString.prefix(5)) " +
            "source=\(source) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
    }

    func detachedDeveloperToolsWindowBelongsToPanel(_ window: NSWindow) -> Bool {
        guard let frontendWebView = webView.cmuxInspectorFrontendWebView(),
              let contentView = window.contentView else {
            return false
        }
        guard isDetachedDeveloperToolsWindowCandidate(window, contentView: contentView) else { return false }
        guard webView !== contentView, !webView.isDescendant(of: contentView) else { return false }
        return frontendWebView === contentView || frontendWebView.isDescendant(of: contentView)
    }

    func isDetachedDeveloperToolsWindowCandidate(_ window: NSWindow, contentView: NSView) -> Bool {
        if let mainWindow = webView.window, window === mainWindow {
            return false
        }
        if window.identifier?.rawValue.hasPrefix("cmux.main.") == true {
            return false
        }
        return !Self.windowContainsBrowserSlotView(contentView)
    }

    static func windowContainsBrowserSlotView(_ root: NSView) -> Bool {
        var stack = [root]
        while let view = stack.popLast() {
            if view is WindowBrowserSlotView {
                return true
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    func shouldDismissDetachedDeveloperToolsWindows() -> Bool {
        preferredDeveloperToolsPresentation == .attached
    }

    func dismissDetachedDeveloperToolsWindowsIfNeeded() {
        guard shouldDismissDetachedDeveloperToolsWindows() else { return }
        guard preferredDeveloperToolsVisible || isDeveloperToolsVisible() else { return }
        let detachedWindows = detachedDeveloperToolsWindowsForPanel()
        guard !detachedWindows.isEmpty else {
            return
        }
        setPreferredDeveloperToolsPresentation(.detached)
        normalizeDeveloperToolsDockControls()
#if DEBUG
        cmuxDebugLog(
            "browser.devtools strayWindow.userDetached panel=\(id.uuidString.prefix(5)) " +
            "count=\(detachedWindows.count) \(debugDeveloperToolsStateSummary()) \(debugDeveloperToolsGeometrySummary())"
        )
#endif
        cancelDetachedDeveloperToolsWindowDismissal()
    }

    func scheduleDetachedDeveloperToolsWindowDismissal() {
        guard shouldDismissDetachedDeveloperToolsWindows() else { return }
        cancelDetachedDeveloperToolsWindowDismissal()
        for delay in [Duration.zero, .milliseconds(150)] {
            let task = Task { @MainActor [weak self] in
                if delay > .zero {
                    try? await ContinuousClock().sleep(for: delay)
                }
                guard !Task.isCancelled else { return }
                self?.dismissDetachedDeveloperToolsWindowsIfNeeded()
            }
            detachedDeveloperToolsWindowDismissalTasks.append(task)
        }
    }
}
