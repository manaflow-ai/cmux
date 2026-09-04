public import AppKit
public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
internal import CMUXAgentLaunch
internal import Darwin
#if DEBUG
internal import CMUXDebugLog
#endif
// MARK: - Headless bootstrap windows and runtime surface lifecycle
extension TerminalSurface {
    @MainActor
    func scheduleHeadlessRuntimeStartIfNeeded(
        reason: String,
        source: RuntimeSurfaceCreationSource = .normal
    ) {
        startRuntimeUsingHeadlessWindowIfNeeded(reason: reason, source: source)
    }

    @MainActor
    private func startRuntimeUsingHeadlessWindowIfNeeded(
        reason: String,
        source: RuntimeSurfaceCreationSource
    ) {
        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }
        ensureHeadlessStartupWindowIfNeeded(reason: reason)
        // Production pane hosts synchronously call attachToView; carry the requested creation source through that callback.
        let previousAttachCreationSource = paneHostAttachCreationSource
        paneHostAttachCreationSource = source
        paneHost.attachSurface(self)
        paneHostAttachCreationSource = previousAttachCreationSource
        if source == .inputDemand, surface == nil, attachedView !== surfaceView {
            attachToViewForInputDemand(surfaceView)
        }
    }

    @MainActor
    private func ensureHeadlessStartupWindowIfNeeded(reason: String) {
        if let existingWindow = headlessStartupWindow {
            guard paneHost.window !== existingWindow else { return }
            if paneHost.window != nil {
                // The pane host reached a real window while a bootstrap
                // window was still recorded; the bootstrap is stale.
                headlessStartupWindow = nil
                existingWindow.contentView = nil
                existingWindow.close()
                return
            }
            // Window-portal churn can reparent the pane host out of the
            // bootstrap window and park it with no window at all
            // (detachHostedView ends in removeFromSuperview). Reclaim custody
            // instead of early-returning: otherwise every later cold start
            // defers on the missing window and the surface never spawns a
            // PTY (#9769).
            adoptPaneHostIntoHeadlessStartupWindow(existingWindow, reason: reason)
            return
        }
        guard paneHost.window == nil else { return }
        let width = max(surfaceView.bounds.width, CGFloat(800))
        let height = max(surfaceView.bounds.height, CGFloat(600))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true
        window.contentView = NSView(frame: frame)
        headlessStartupWindow = window
        adoptPaneHostIntoHeadlessStartupWindow(window, reason: reason)

#if DEBUG
        logDebugEvent(
            "surface.headless_window.create surface=\(id.uuidString.prefix(8)) " +
            "reason=\(reason) window=\(ObjectIdentifier(window))"
        )
#endif
    }

    @MainActor
    private func adoptPaneHostIntoHeadlessStartupWindow(_ window: NSWindow, reason: String) {
        guard let contentView = window.contentView else { return }
        paneHost.frame = contentView.bounds
        paneHost.autoresizingMask = [.width, .height]
        contentView.addSubview(paneHost)
        paneHost.setVisibleInUI(false)
        paneHost.setActive(false)

#if DEBUG
        logDebugEvent(
            "surface.headless_window.adopt surface=\(id.uuidString.prefix(8)) " +
            "reason=\(reason) window=\(ObjectIdentifier(window))"
        )
#endif
    }

    @MainActor
    func releaseHeadlessStartupWindowIfNeeded(for view: any TerminalSurfaceNativeViewing) {
        guard let window = headlessStartupWindow else { return }
        guard let currentWindow = view.window, currentWindow !== window else { return }
        headlessStartupWindow = nil
        window.contentView = nil
        window.close()
#if DEBUG
        logDebugEvent(
            "surface.headless_window.release surface=\(id.uuidString.prefix(8)) " +
            "realWindow=\(ObjectIdentifier(currentWindow))"
        )
#endif
    }

    @MainActor
    func closeHeadlessStartupWindowIfNeeded() {
        // Isolation note: the legacy helper accepted off-main callers with a
        // Thread.isMainThread check + main-queue hop. Every caller
        // (teardownSurface, agent-hibernation suspend) is main-actor isolated,
        // so the hop was dead and the method is now @MainActor; deinit has its
        // own transport-based hop.
        let startupWindow = headlessStartupWindow
        headlessStartupWindow = nil
        guard let startupWindow else { return }
        startupWindow.contentView = nil
        startupWindow.close()
    }

    /// Reasserts the runtime display id after the view (re)enters a window.
    @MainActor
    public func reconcileAttachedWindowIfNeeded(for view: any TerminalSurfaceNativeViewing) {
        guard attachedView === view else { return }
        releaseHeadlessStartupWindowIfNeeded(for: view)
        if let screen = view.window?.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0,
           let s = liveSurfaceForGhosttyAccess(reason: "reconcileAttachedWindow") {
            ghostty_surface_set_display_id(s, displayID)
        }
        if isViewInWindow {
            onManualWindowAttached?()
        }
        rendererPresentationReadinessDidChange()
    }

    /// Whether the surface model is attached to `view` with a live runtime
    /// surface.
    @MainActor
    public func isAttached(to view: any TerminalSurfaceNativeViewing) -> Bool {
        attachedView === view && surface != nil
    }

    /// Validates the runtime pointer (registry ownership + allocation
    /// liveness) before handing it to a Ghostty C API; quarantines and tears
    /// down a stale wrapper instead of returning a dangling pointer.
    @MainActor
    public func liveSurfaceForGhosttyAccess(reason: String) -> ghostty_surface_t? {
        guard hasLiveSurface, let surface else { return nil }
        let registeredOwnerId = registry.runtimeSurfaceOwnerId(surface)
        guard registeredOwnerId == id,
              GhosttySurfaceRuntimeProbe.surfacePointerAppearsLive(surface) else {
            let callbackContext = surfaceCallbackContext
            invalidateRuntimeClipboardRequests(in: callbackContext, completingNativeRequests: false)
            surfaceCallbackContext = nil
            let manualIOContext = self.manualIOContext
            self.manualIOContext = nil
            let teeLease = mobileByteTeeLease
            mobileByteTeeLease = nil
            let retiredRemoteOutputLane = retireRemoteOutputLane()
            let staleRuntimeResources = TerminalSurfaceStaleRuntimeResources(
                callbackContext: callbackContext,
                manualIOContext: manualIOContext,
                byteTeeLease: teeLease
            )
            staleRuntimeResourceReleaseTicket = runtimeTeardown.enqueueRuntimeTeardownFence(
                id: UUID(),
                workspaceId: tabId,
                reason: "stale",
                fence: {
                    await retiredRemoteOutputLane.drain()
                },
                onCompletion: {
                    staleRuntimeResources.release()
                }
            )
            registry.unregisterRuntimeSurface(surface, ownerId: id)
            self.surface = nil
            activePortalHostLease = nil
            portalHostAuthority = nil
            byteTee.dropSurface(surfaceID: id)
            recordTeardownRequest(reason: reason)
            markPortalLifecycleClosed(reason: reason)
#if DEBUG
            let registeredOwnerToken = registeredOwnerId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            logDebugEvent(
                "surface.lifecycle.stale surface=\(id.uuidString.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
                "registryOwner=\(registeredOwnerToken)"
            )
#endif
            return nil
        }
        return surface
    }

    func recordTeardownRequest(reason: String) {
        withDebugMetadataLock {
            if teardownRequestedAt == nil {
                teardownRequestedAt = Date()
            }
            if let existing = teardownRequestReason, !existing.isEmpty {
                return
            }
            teardownRequestReason = reason
        }
    }

    func recordRuntimeSurfaceCreation() {
        withDebugMetadataLock {
            runtimeSurfaceCreatedAt = Date()
        }
    }

    func allowsRuntimeSurfaceCreation() -> Bool {
        portalLifecycleState == .live &&
            !runtimeSurfaceSuspendedForAgentHibernation &&
            startupRestoreAdmissionPhase != .awaitingAdmission
    }

    /// Whether the surface lifecycle currently permits creating a runtime
    /// surface (portal live, admitted, and not suspended for agent hibernation).
    ///
    /// Background priming uses this to skip surfaces whose spawn can never
    /// complete instead of retaining a hidden mount slot for them forever.
    public var canCreateRuntimeSurface: Bool {
        allowsRuntimeSurfaceCreation()
    }

    private var hasDeferredStartupWork: Bool {
        let inheritedCommand = configTemplate?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedInput = configTemplate?.initialInput
        return initialCommand != nil ||
            tmuxStartCommand != nil ||
            initialInput != nil ||
            inheritedCommand?.isEmpty == false ||
            inheritedInput?.isEmpty == false ||
            pendingSocketInputBytes > 0
    }

    /// Whether this surface has startup work that justifies a background
    /// runtime start.
    public func hasDeferredStartupWorkForBackgroundStart() -> Bool {
        hasDeferredStartupWork
    }

    /// Marks the portal as closing (close animation/teardown has begun).
    public func beginPortalCloseLifecycle(reason: String) {
        guard portalLifecycleState != .closed else { return }
        guard portalLifecycleState != .closing else { return }
        recordTeardownRequest(reason: reason)
        portalLifecycleState = .closing
        // Parked wake-ups are for re-anchoring live content; a closing surface
        // has none, and the park guard refuses new entries from here on.
        clearPortalHostVacancyRetries()
        portalLifecycleGeneration &+= 1
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.close.begin surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    func markPortalLifecycleClosed(reason: String) {
        guard portalLifecycleState != .closed else { return }
        portalLifecycleState = .closed
        portalLifecycleGeneration &+= 1
        clearPortalHostVacancyRetries()
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.close.sealed surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    /// Explicitly retire this model and free its Ghostty runtime surface.
    /// Idempotent — safe to call before deinit; deinit will skip the work if
    /// already torn down.
    @MainActor
    public func teardownSurface() {
        recordTeardownRequest(reason: "surface.teardown")
        markPortalLifecycleClosed(reason: "teardown")
        retireSurfaceRegistryRegistrationIfNeeded()
        backgroundSurfaceStartSource = .normal
        cancelAgentCommandShimInstallLifecycle()
        closeHeadlessStartupWindowIfNeeded()
        let callbackContext = surfaceCallbackContext
        let surfaceToFree = surface
        let retiredRemoteOutputLane = retireRemoteOutputLane()
        invalidateRuntimeClipboardRequests(in: callbackContext, completingNativeRequests: surfaceToFree != nil)
        surfaceCallbackContext = nil
        let manualIOContext = manualIOContext
        self.manualIOContext = nil
        let teeLease = mobileByteTeeLease
        mobileByteTeeLease = nil
        byteTee.dropSurface(surfaceID: id)
        if let surfaceToFree {
            registry.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil
        guard let surfaceToFree else {
            callbackContext?.release()
            manualIOContext?.release()
            teeLease?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
            manualIOContext?.release()
            teeLease?.release()
            return
        }
#endif
#if DEBUG
        if let freeSurface = Self.runtimeSurfaceFreeOverrideForTesting {
            // Transport manualIOContext and teeLease through the request too:
            // the coordinator releases all callback userdata only after the
            // native free, which is what joins ghostty's IO threads.
            runtimeTeardown.enqueueRuntimeTeardown(
                id: id,
                workspaceId: tabId,
                reason: "teardown",
                surface: surfaceToFree,
                callbackContext: callbackContext,
                manualIOContext: manualIOContext,
                byteTeeLease: teeLease,
                beforeFree: {
                    await retiredRemoteOutputLane.drain()
                },
                freeSurface: freeSurface
            )
            return
        }
#endif

        runtimeTeardown.enqueueRuntimeTeardown(
            id: id,
            workspaceId: tabId,
            reason: "teardown",
            surface: surfaceToFree,
            callbackContext: callbackContext,
            manualIOContext: manualIOContext,
            byteTeeLease: teeLease,
            beforeFree: {
                await retiredRemoteOutputLane.drain()
            }
        )
    }

    /// Frees the runtime surface while keeping the model alive for an
    /// agent-hibernation resume.
    ///
    /// - Returns: `false` without changing the surface when the bounded
    ///   hibernation teardown lane has no capacity.
    @discardableResult
    @MainActor
    public func suspendRuntimeSurfaceForAgentHibernation(reason: String) -> Bool {
        guard let teardownReservation =
                agentHibernationRuntimeTeardownReservation ??
                runtimeTeardown.reserveIsolatedHibernationTeardown() else {
            return false
        }
        agentHibernationRuntimeTeardownReservation = nil
        _ = fontSizeLineageSnapshot()
        mobileViewportFontFitState = nil
        if !runtimeSurfaceSuspendedForAgentHibernation {
            // End the child-process generation at the successful suspension
            // boundary. The registry advances first, synchronously rejecting
            // delayed reports before this main-actor model exports the token
            // to the replacement runtime.
            advanceTerminalLifecycleForRuntimeReplacement()
        }
        runtimeSurfaceSuspendedForAgentHibernation = true
        backgroundSurfaceStartQueued = false
        backgroundSurfaceStartSource = .normal
        cancelAgentCommandShimInstallLifecycle()
        closeHeadlessStartupWindowIfNeeded()
        let callbackContext = surfaceCallbackContext
        let surfaceToFree = surface
        let retiredRemoteOutputLane = retireRemoteOutputLane()
        invalidateRuntimeClipboardRequests(in: callbackContext, completingNativeRequests: surfaceToFree != nil)
        surfaceCallbackContext = nil
        let manualIOContext = manualIOContext
        self.manualIOContext = nil
        let teeLease = mobileByteTeeLease
        mobileByteTeeLease = nil
        byteTee.dropSurface(surfaceID: id)

        if let surfaceToFree {
            registry.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil
        activePortalHostLease = nil
        portalHostAuthority = nil
        clearPortalHostVacancyRetries()
        portalLifecycleGeneration &+= 1
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        desiredFocusState = false

        guard let surfaceToFree else {
            runtimeTeardown.cancelIsolatedHibernationTeardown(
                teardownReservation
            )
            callbackContext?.release()
            manualIOContext?.release()
            teeLease?.release()
            return true
        }

#if DEBUG
        logDebugEvent(
            "surface.lifecycle.hibernate surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif

#if DEBUG
        if let freeSurface = Self.runtimeSurfaceFreeOverrideForTesting {
            // Transport manualIOContext and teeLease through the request too:
            // the coordinator releases all callback userdata only after the
            // native free, which is what joins ghostty's IO threads.
            agentHibernationRuntimeTeardownTicket = runtimeTeardown.enqueueRuntimeTeardown(
                id: id,
                workspaceId: tabId,
                reason: reason,
                surface: surfaceToFree,
                callbackContext: callbackContext,
                manualIOContext: manualIOContext,
                byteTeeLease: teeLease,
                beforeFree: {
                    await retiredRemoteOutputLane.drain()
                },
                executionLane: .isolatedHibernation,
                isolatedHibernationReservation: teardownReservation,
                freeSurface: freeSurface
            )
            return true
        }
#endif

        agentHibernationRuntimeTeardownTicket = runtimeTeardown.enqueueRuntimeTeardown(
            id: id,
            workspaceId: tabId,
            reason: reason,
            surface: surfaceToFree,
            callbackContext: callbackContext,
            manualIOContext: manualIOContext,
            byteTeeLease: teeLease,
            beforeFree: {
                await retiredRemoteOutputLane.drain()
            },
            executionLane: .isolatedHibernation,
            isolatedHibernationReservation: teardownReservation
        )
        return true
    }

    /// Reserves the bounded native-free lane at the final pre-signal gate.
    @MainActor
    public func reserveAgentHibernationRuntimeTeardown() -> Bool {
        guard agentHibernationRuntimeTeardownTicket == nil else { return false }
        if agentHibernationRuntimeTeardownReservation != nil { return true }
        guard let reservation =
                runtimeTeardown.reserveIsolatedHibernationTeardown() else {
            return false
        }
        agentHibernationRuntimeTeardownReservation = reservation
        return true
    }

    /// Releases an unused reservation when the signal batch fails before commit.
    @MainActor
    public func cancelAgentHibernationRuntimeTeardownReservation() {
        guard let reservation = agentHibernationRuntimeTeardownReservation else {
            return
        }
        agentHibernationRuntimeTeardownReservation = nil
        runtimeTeardown.cancelIsolatedHibernationTeardown(reservation)
    }

    /// Waits for the old hibernated runtime generation to finish native teardown.
    ///
    /// - Parameter timeout: Maximum wait, or `nil` for event-driven recovery.
    /// - Returns: `true` only after the old native surface and callback contexts are gone.
    @MainActor
    public func waitForAgentHibernationRuntimeTeardown(timeout: Duration?) async -> Bool {
        guard let ticket = agentHibernationRuntimeTeardownTicket else { return true }
        let completed = await ticket.wait(timeout: timeout)
        if completed, agentHibernationRuntimeTeardownTicket?.id == ticket.id {
            agentHibernationRuntimeTeardownTicket = nil
        }
        return completed
    }

    /// Marks the resume side of agent hibernation and primes the next runtime
    /// spawn's initial input.
    ///
    /// - Returns: `true` when the old runtime is fully gone and resume was armed.
    @discardableResult
    @MainActor
    public func prepareAgentHibernationResume(initialInput: String?) -> Bool {
        guard agentHibernationRuntimeTeardownTicket == nil else { return false }
        runtimeSurfaceSuspendedForAgentHibernation = false
        prepareNextRuntimeInitialInput(initialInput)
        return true
    }

    /// Sets the transport-only command used when a deferred restore is cancelled.
    ///
    /// Persistent SSH restores keep their PTY attached after cancellation, but
    /// must omit the embedded agent-resume payload. The value is captured when
    /// admission is cancelled and remains in force for later runtime retries.
    ///
    /// - Parameter command: The transport-only command to run after cancellation.
    @MainActor
    public func setStartupRestoreAdmissionFallbackCommand(_ command: String?) {
        guard startupRestoreAdmissionPhase == .awaitingAdmission else { return }
        startupRestoreAdmissionFallbackCommand = command?.isEmpty == false ? command : nil
    }

    /// Primes the initial input for the next runtime spawn only.
    public func prepareNextRuntimeInitialInput(_ input: String?) {
        let trimmedInput = input?.isEmpty == false ? input : nil
        nextRuntimeInitialInput = trimmedInput
    }

    /// Attaches the model to its inner view, creating the runtime surface
    /// when the view is in a window.
    @MainActor
    public func attachToView(_ view: any TerminalSurfaceNativeViewing) {
#if DEBUG
        logDebugEvent(
            "surface.attach surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view as NSView).toOpaque()) " +
            "attached=\(attachedView != nil ? 1 : 0) hasSurface=\(surface != nil ? 1 : 0) inWindow=\(view.window != nil ? 1 : 0)"
        )
#endif

        // If already attached to this view, nothing to do.
        // Still re-assert the display id: during split close tree restructuring, the view can be
        // removed/re-added (or briefly have window/screen nil) without recreating the surface.
        // Ghostty's renderer depends on a valid display id; if it is missing or stale,
        // the surface can freeze visually until focus/visibility changes. Avoid forcing refresh when the attachment
        // itself is unchanged.
        if attachedView === view && surface != nil {
            releaseHeadlessStartupWindowIfNeeded(for: view)
            flushPendingManualSizeReportIfAttached()
            if isViewInWindow {
                onManualWindowAttached?()
            }
#if DEBUG
            logDebugEvent("surface.attach.reuse surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view as NSView).toOpaque())")
#endif
            if let screen = view.window?.screen ?? NSScreen.main,
               let displayID = screen.displayID,
               displayID != 0,
               let s = surface {
                ghostty_surface_set_display_id(s, displayID)
            }
            rendererPresentationReadinessDidChange()
            return
        }

        if let attachedView, attachedView !== view {
#if DEBUG
            logDebugEvent(
                "surface.attach.skip surface=\(id.uuidString.prefix(5)) reason=alreadyAttachedToDifferentView " +
                "current=\(Unmanaged.passUnretained(attachedView as NSView).toOpaque()) new=\(Unmanaged.passUnretained(view as NSView).toOpaque())"
            )
#endif
            return
        }

        attachedView = view
        releaseHeadlessStartupWindowIfNeeded(for: view)

        if isViewInWindow {
            onManualWindowAttached?()
        }

        // Ordinary portal attachment can arrive before AppKit has put the view in
        // a window. Defer those. Startup and cold-input paths install the owned
        // view in a hidden bootstrap window first, then come through here.
        if surface == nil {
            guard allowsRuntimeSurfaceCreation() else {
#if DEBUG
                logDebugEvent(
                    "surface.attach.skip surface=\(id.uuidString.prefix(5)) " +
                    "reason=lifecycle.\(portalLifecycleState.rawValue)"
                )
#endif
                return
            }
            guard view.window != nil else {
#if DEBUG
                logDebugEvent(
                    "surface.attach.defer surface=\(id.uuidString.prefix(5)) reason=noWindow " +
                    "bounds=\(String(format: "%.1fx%.1f", Double(view.bounds.width), Double(view.bounds.height)))"
                )
#endif
                return
            }
#if DEBUG
            logDebugEvent(
                "surface.attach.create surface=\(id.uuidString.prefix(5)) " +
                "inWindow=\(view.window != nil ? 1 : 0)"
            )
#endif
            createSurface(for: view, source: paneHostAttachCreationSource)
#if DEBUG
            logDebugEvent("surface.attach.create.done surface=\(id.uuidString.prefix(5)) hasSurface=\(surface != nil ? 1 : 0)")
#endif
        } else if let screen = view.window?.screen ?? NSScreen.main,
                  let displayID = screen.displayID,
                  displayID != 0,
                  let s = surface {
            // Surface exists but we're (re)attaching after a view hierarchy move; ensure display id.
            ghostty_surface_set_display_id(s, displayID)
#if DEBUG
            logDebugEvent("surface.attach.displayId surface=\(id.uuidString.prefix(5)) display=\(displayID)")
#endif
        }
        rendererPresentationReadinessDidChange()
    }

    @MainActor
    func createSurface(for view: any TerminalSurfaceNativeViewing) {
        createSurface(for: view, source: .normal)
    }

    @MainActor
    private func deferRuntimeSurfaceCreationForConfigurationReload(
        view: any TerminalSurfaceNativeViewing,
        source: RuntimeSurfaceCreationSource
    ) -> Bool {
        if configurationReloadDeferredRuntimeSurfaceCreation {
            configurationReloadDeferredRuntimeSurfaceCreationSource =
                (
                    configurationReloadDeferredRuntimeSurfaceCreationSource
                    ?? source
                ).promoted(with: source)
            configurationReloadDeferredRuntimeSurfaceView = view
            return true
        }

        configurationReloadDeferredRuntimeSurfaceCreation = true
        configurationReloadDeferredRuntimeSurfaceCreationSource =
            source
        configurationReloadDeferredRuntimeSurfaceView = view
        let accepted =
            engine
                .deferRuntimeSurfaceCreationForConfigurationReload {
                    [weak self] in
                    self?
                        .resumeRuntimeSurfaceCreationAfterConfigurationReload()
                }
        guard accepted else {
            configurationReloadDeferredRuntimeSurfaceCreation = false
            configurationReloadDeferredRuntimeSurfaceCreationSource =
                nil
            configurationReloadDeferredRuntimeSurfaceView = nil
            return false
        }
        return true
    }

    @MainActor
    private func resumeRuntimeSurfaceCreationAfterConfigurationReload() {
        let source =
            configurationReloadDeferredRuntimeSurfaceCreationSource
            ?? .normal
        let view =
            configurationReloadDeferredRuntimeSurfaceView
            ?? attachedView
            ?? surfaceView
        configurationReloadDeferredRuntimeSurfaceCreation = false
        configurationReloadDeferredRuntimeSurfaceCreationSource = nil
        configurationReloadDeferredRuntimeSurfaceView = nil

        guard allowsRuntimeSurfaceCreation(),
              surface == nil else {
            return
        }
        prepareFontSizeForDeferredConfigurationRuntimeCreation()
        createSurface(for: view, source: source)
    }

    @MainActor
    func createSurface(for view: any TerminalSurfaceNativeViewing, source: RuntimeSurfaceCreationSource) {
        guard allowsRuntimeSurfaceCreation() else {
#if DEBUG
            logDebugEvent(
                "surface.create.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=lifecycle.\(portalLifecycleState.rawValue)"
            )
            Self.surfaceLog(
                "createSurface SKIPPED surface=\(id.uuidString) tab=\(tabId.uuidString) lifecycle=\(portalLifecycleState.rawValue)"
            )
#endif
            return
        }
        if deferRuntimeSurfaceCreationForConfigurationReload(
            view: view,
            source: source
        ) {
            return
        }
        let agentShimState = agentCommandShimStateForSurface(view: view, source: source)
        guard agentShimState.isReady else { return }
        if shouldPaceRuntimeSurfaceCreation(source: source) {
            enqueueRestoredRuntimeSurfaceCreation(for: view)
            return
        }
        let agentCommandShims = agentShimState.shims
#if DEBUG
        runtimeSurfaceCreateAttemptCountForTesting += 1
#endif
        #if DEBUG
        let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap { String(cString: $0) } ?? "(unset)"
        let terminfo = getenv("TERMINFO").flatMap { String(cString: $0) } ?? "(unset)"
        let xdg = getenv("XDG_DATA_DIRS").flatMap { String(cString: $0) } ?? "(unset)"
        let manpath = getenv("MANPATH").flatMap { String(cString: $0) } ?? "(unset)"
        Self.surfaceLog("createSurface start surface=\(id.uuidString) tab=\(tabId.uuidString) bounds=\(view.bounds) inWindow=\(view.window != nil) resources=\(resourcesDir) terminfo=\(terminfo) xdg=\(xdg) manpath=\(manpath)")
        #endif

        guard let app = engine.runtimeApp else {
            #if DEBUG
            logDebugEvent("ghostty.surface.create.failed reason=appNotInitialized surface=\(id.uuidString)")
            #endif
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty app not initialized")
            #endif
            return
        }

        let scaleFactors = scaleFactors(for: view)

        let runtimeSurfaceCreation = createNativeRuntimeSurface(
            app: app,
            for: view,
            scaleFactors: scaleFactors,
            agentCommandShims: agentCommandShims
        )
        surface = runtimeSurfaceCreation.createdSurface
        let runtimeInitialInput = runtimeSurfaceCreation.runtimeInitialInput

        if surface == nil {
            invalidateRuntimeClipboardRequests(in: surfaceCallbackContext, completingNativeRequests: false)
            surfaceCallbackContext?.release()
            surfaceCallbackContext = nil
            manualIOContext?.release()
            manualIOContext = nil
            #if DEBUG
            logDebugEvent("ghostty.surface.create.failed reason=surfaceNewNil surface=\(id.uuidString)")
            #endif
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty_surface_new returned nil")
            if let cfg = engine.runtimeConfig {
                let count = Int(ghostty_config_diagnostics_count(cfg))
                Self.surfaceLog("createSurface diagnostics count=\(count)")
                for i in 0..<count {
                    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                    let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
                    Self.surfaceLog("  [\(i)] \(msg)")
                }
            } else {
                Self.surfaceLog("createSurface diagnostics: config=nil")
            }
            #endif
            return
        }
        guard let createdSurface = surface else { return }
        guard let surfaceCallbackContext else {
            preconditionFailure(
                "A native terminal surface requires callback userdata"
            )
        }
        _ = surfaceCallbackContext.takeUnretainedValue()
            .bindRuntimeClipboardSurface(
                createdSurface,
                generation: runtimeSurfaceGeneration
            )
        installFontSizeActionObservation(
            on: createdSurface,
            callbackContext: surfaceCallbackContext
        )
        if source == .scheduledRestore || source == .inputDemand {
            requiresRestoreSpawnPacing = false
        }
        registry.registerRuntimeSurface(createdSurface, ownerId: id)
        cacheControllingTTYIdentity(for: createdSurface)
        recordRuntimeSurfaceCreation()
        // Install the shared PTY tee so output consumers receive every byte
        // the read thread produces, in order, before the VT parser runs.
        // Paired iPhones consume these bytes via `terminal.bytes` events
        // and feed them into their own libghostty surface, guaranteeing
        // grid parity by construction. The lease is released alongside
        // `surfaceCallbackContext` when the surface tears down.
        mobileByteTeeLease?.release()
        mobileByteTeeLease = byteTee.installTee(on: createdSurface, workspaceID: tabId, surfaceID: id)
        if runtimeInitialInput != nil {
            nextRuntimeInitialInput = nil
        }
        // Session scrollback replay must be one-shot. Reusing it on a later runtime
        // surface recreation would inject stale restored output into a live shell.
        additionalEnvironment.removeValue(forKey: scrollbackReplayEnvironmentKey)

        // For vsync-driven rendering, Ghostty needs to know which display we're on so it can
        // start a CVDisplayLink with the right refresh rate. If we don't set this early, the
        // renderer can believe vsync is "running" but never deliver frames, which looks like a
        // frozen terminal until focus/visibility changes force a synchronous draw.
        //
        // `view.window?.screen` can be transiently nil during early attachment; fall back to the
        // primary screen so we always set *some* display ID, then update again on screen changes.
        if let screen = view.window?.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(createdSurface, displayID)
        }

        ghostty_surface_set_content_scale(createdSurface, scaleFactors.x, scaleFactors.y)
        let backingSize = view.convertToBacking(NSRect(origin: .zero, size: view.bounds.size)).size
        let wpx = pixelDimension(from: backingSize.width)
        let hpx = pixelDimension(from: backingSize.height)
        if wpx > 0, hpx > 0 {
            applySurfaceSize(
                createdSurface,
                width: wpx,
                height: hpx,
                caller: "runtime.create.initial"
            )
            lastPixelWidth = wpx
            lastPixelHeight = hpx
            lastUncappedPixelWidth = wpx
            lastUncappedPixelHeight = hpx
            lastXScale = scaleFactors.x
            lastYScale = scaleFactors.y
        }

        // Flush remote-tmux output that arrived before the surface existed
        // after sizing, so the seed paints into the final grid instead of
        // wrapping at Ghostty's default grid.
        flushPendingRemoteOutput(to: createdSurface)

        // Some GhosttyKit builds can drop explicit font_size during post-create
        // config/scale reconciliation. Re-apply explicit runtime points so
        // Ghostty retains surface-local ownership; otherwise Cmd+0 could not
        // clear the restored override for the next snapshot. Non-explicit
        // lineage intentionally reconciles to the current terminal config.
        if let inheritedFontSizeLineage = lastKnownFontSizeLineage,
           inheritedFontSizeLineage.isExplicitOverride,
           inheritedFontSizeLineage.basePoints > 0 {
            let inheritedBaseFontPoints = inheritedFontSizeLineage.basePoints
            let inheritedRuntimeFontPoints = CmuxSurfaceConfigTemplate.runtimeFontSize(fromBasePoints: inheritedBaseFontPoints, percent: globalFontMagnificationPercent())
            let action =
                ghosttySetFontSizeBindingAction(
                    inheritedRuntimeFontPoints
                )
            _ = performInternalBindingAction(action)
        }

        // Re-apply the desired focus state after creation so the live runtime
        // surface converges with any focus changes that happened while the
        // surface was being initialized.
        ghostty_surface_set_focus(createdSurface, desiredFocusState)

        flushPendingSocketInputIfNeeded()
        view.runtimeSurfaceDidBecomeReady()

        // Kick an initial draw after creation/size setup. On some startup paths Ghostty can
        // miss the first vsync callback and sit on a blank frame until another focus/visibility
        // transition nudges the renderer.
        view.forceRefreshSurface()
        ghostty_surface_refresh(createdSurface)
        rendererRuntimeSurfaceDidCreate()

        NotificationCenter.default.post(
            name: .terminalSurfaceDidBecomeReady,
            object: self,
            userInfo: [
                "surfaceId": id,
                "workspaceId": tabId
            ]
        )
        onRuntimeReady?()
#if DEBUG
        let runtimeFontText = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(createdSurface).map {
            String(format: "%.2f", $0)
        } ?? "nil"
        logDebugEvent(
            "zoom.create.done surface=\(id.uuidString.prefix(5)) context=\(GhosttySurfaceRuntimeProbe.contextName(surfaceContext)) " +
            "runtimeFont=\(runtimeFontText)"
        )
#endif
    }

}
