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
        guard headlessStartupWindow == nil else { return }
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
        let contentView = NSView(frame: frame)
        paneHost.frame = contentView.bounds
        paneHost.autoresizingMask = [.width, .height]
        contentView.addSubview(paneHost)
        window.contentView = contentView
        headlessStartupWindow = window
        paneHost.setVisibleInUI(false)
        paneHost.setActive(false)

#if DEBUG
        logDebugEvent(
            "surface.headless_window.create surface=\(id.uuidString.prefix(8)) " +
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
        guard let screen = view.window?.screen ?? NSScreen.main,
              let displayID = screen.displayID,
              displayID != 0 else { return }
        guard let s = liveSurfaceForGhosttyAccess(reason: "reconcileAttachedWindow") else { return }
        ghostty_surface_set_display_id(s, displayID)
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
            surfaceCallbackContext = nil
            let teeLease = mobileByteTeeLease
            mobileByteTeeLease = nil
            registry.unregisterRuntimeSurface(surface, ownerId: id)
            self.surface = nil
            activePortalHostLease = nil
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
            callbackContext?.release()
            teeLease?.release()
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
        portalLifecycleState == .live && !runtimeSurfaceSuspendedForAgentHibernation
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
#if DEBUG
        logDebugEvent(
            "surface.lifecycle.close.sealed surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    /// Explicitly free the Ghostty runtime surface. Idempotent — safe to call
    /// before deinit; deinit will skip the free if already torn down.
    @MainActor
    public func teardownSurface() {
        recordTeardownRequest(reason: "surface.teardown")
        markPortalLifecycleClosed(reason: "teardown")
        backgroundSurfaceStartSource = .normal
        cancelClaudeCommandShimInstallLifecycle()
        closeHeadlessStartupWindowIfNeeded()

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let manualIOContext = manualIOContext
        self.manualIOContext = nil
        let teeLease = mobileByteTeeLease
        mobileByteTeeLease = nil
        byteTee.dropSurface(surfaceID: id)

        let surfaceToFree = surface
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
            runtimeTeardown.enqueueRuntimeTeardown(
                id: id,
                workspaceId: tabId,
                reason: "teardown",
                surface: surfaceToFree,
                callbackContext: callbackContext,
                freeSurface: freeSurface
            )
            // The teardown coordinator releases callbackContext; manualIOContext
            // and teeLease are not transported through the request, so release them here.
            manualIOContext?.release()
            teeLease?.release()
            return
        }
#endif

        Task { @MainActor in
            // Keep free behavior aligned with deinit: perform the runtime teardown on
            // the next main-actor turn so SIGHUP delivery is deterministic but non-reentrant.
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            manualIOContext?.release()
            teeLease?.release()
        }
    }

    /// Frees the runtime surface while keeping the model alive for an
    /// agent-hibernation resume.
    @MainActor
    public func suspendRuntimeSurfaceForAgentHibernation(reason: String) {
        runtimeSurfaceSuspendedForAgentHibernation = true
        backgroundSurfaceStartQueued = false
        backgroundSurfaceStartSource = .normal
        cancelClaudeCommandShimInstallLifecycle()
        closeHeadlessStartupWindowIfNeeded()
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let manualIOContext = manualIOContext
        self.manualIOContext = nil
        let teeLease = mobileByteTeeLease
        mobileByteTeeLease = nil
        byteTee.dropSurface(surfaceID: id)

        let surfaceToFree = surface
        if let surfaceToFree {
            registry.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil
        activePortalHostLease = nil
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        desiredFocusState = false

        guard let surfaceToFree else {
            callbackContext?.release()
            manualIOContext?.release()
            teeLease?.release()
            return
        }

#if DEBUG
        logDebugEvent(
            "surface.lifecycle.hibernate surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif

#if DEBUG
        if let freeSurface = Self.runtimeSurfaceFreeOverrideForTesting {
            runtimeTeardown.enqueueRuntimeTeardown(
                id: id,
                workspaceId: tabId,
                reason: reason,
                surface: surfaceToFree,
                callbackContext: callbackContext,
                freeSurface: freeSurface
            )
            // The teardown coordinator releases callbackContext; manualIOContext
            // and teeLease are not transported through the request, so release them here.
            manualIOContext?.release()
            teeLease?.release()
            return
        }
#endif

        Task { @MainActor in
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            manualIOContext?.release()
            teeLease?.release()
        }
    }

    /// Marks the resume side of agent hibernation and primes the next runtime
    /// spawn's initial input.
    @MainActor
    public func prepareAgentHibernationResume(initialInput: String?) {
        runtimeSurfaceSuspendedForAgentHibernation = false
        prepareNextRuntimeInitialInput(initialInput)
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
#if DEBUG
            logDebugEvent("surface.attach.reuse surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view as NSView).toOpaque())")
#endif
            if let screen = view.window?.screen ?? NSScreen.main,
               let displayID = screen.displayID,
               displayID != 0,
               let s = surface {
                ghostty_surface_set_display_id(s, displayID)
            }
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
    }

    @MainActor
    func createSurface(for view: any TerminalSurfaceNativeViewing) {
        createSurface(for: view, source: .normal)
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
        let claudeShimState = claudeCommandShimStateForSurface(view: view, source: source)
        guard claudeShimState.isReady else { return }
        if shouldPaceRuntimeSurfaceCreation(source: source) {
            enqueueRestoredRuntimeSurfaceCreation(for: view)
            return
        }
        let claudeShim = claudeShimState.shim
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
            claudeShim: claudeShim
        )
        surface = runtimeSurfaceCreation.createdSurface
        let runtimeInitialInput = runtimeSurfaceCreation.runtimeInitialInput

        if surface == nil {
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
        if source == .scheduledRestore || source == .inputDemand {
            requiresRestoreSpawnPacing = false
        }
        registry.registerRuntimeSurface(createdSurface, ownerId: id)
        // A freshly created runtime surface always owns a live (non-defunct)
        // swap chain, so it is realized. Reset the flag in case this object's
        // previous runtime surface had been released before being freed (e.g.
        // agent-hibernation suspend/restore), which would otherwise let a later
        // realizeRenderer() double-realize and trip Ghostty's defunct assert.
        rendererRealized = true
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
            ghostty_surface_set_size(createdSurface, wpx, hpx)
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

        // Some GhosttyKit builds can drop inherited font_size during post-create
        // config/scale reconciliation. Re-apply runtime points so all creation
        // paths preserve zoom from the source terminal.
        if let inheritedBaseFontPoints = configTemplate?.fontSize,
           inheritedBaseFontPoints > 0 {
            let inheritedRuntimeFontPoints = CmuxSurfaceConfigTemplate.runtimeFontSize(fromBasePoints: inheritedBaseFontPoints, percent: globalFontMagnificationPercent())
            let currentFontPoints = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(createdSurface)
            let shouldReapply = {
                guard let currentFontPoints else { return true }
                return abs(currentFontPoints - inheritedRuntimeFontPoints) > 0.05
            }()
            if shouldReapply {
                let action = String(format: "set_font_size:%.3f", inheritedRuntimeFontPoints)
                _ = performInternalBindingAction(action)
            }
        }

        // Re-apply the desired focus state after creation so the live runtime
        // surface converges with any focus changes that happened while the
        // surface was being initialized.
        ghostty_surface_set_focus(createdSurface, desiredFocusState)

        flushPendingSocketInputIfNeeded()

        // Kick an initial draw after creation/size setup. On some startup paths Ghostty can
        // miss the first vsync callback and sit on a blank frame until another focus/visibility
        // transition nudges the renderer.
        view.forceRefreshSurface()
        ghostty_surface_refresh(createdSurface)

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
