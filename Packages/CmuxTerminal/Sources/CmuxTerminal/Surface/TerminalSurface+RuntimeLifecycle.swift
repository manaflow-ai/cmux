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
    func scheduleHeadlessRuntimeStartIfNeeded(reason: String) {
        startRuntimeUsingHeadlessWindowIfNeeded(reason: reason)
    }

    @MainActor
    private func startRuntimeUsingHeadlessWindowIfNeeded(reason: String) {
        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }
        ensureHeadlessStartupWindowIfNeeded(reason: reason)
        paneHost.attachSurface(self)
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

    /// Returns a live runtime surface for socket/API text reads, starting one if needed.
    ///
    /// Background workspaces may not have a runtime surface until the user
    /// selects them. Socket/API reads are explicit terminal demand, so this
    /// method bootstraps the runtime in the hidden startup window when the
    /// surface is still unopened and the lifecycle permits creation.
    ///
    /// - Parameter reason: A debug/logging reason describing the caller.
    /// - Returns: A live Ghostty surface pointer, or `nil` if startup is not allowed.
    @MainActor
    public func liveSurfaceForSocketRead(reason: String) -> ghostty_surface_t? {
        if let liveSurface = liveSurfaceForGhosttyAccess(reason: reason) {
            return liveSurface
        }
        guard surface == nil, allowsRuntimeSurfaceCreation() else {
#if DEBUG
            logDebugEvent(
                "surface.read_start.skip surface=\(id.uuidString.prefix(8)) " +
                "hasSurface=\(surface != nil ? 1 : 0) lifecycle=\(portalLifecycleState.rawValue)"
            )
#endif
            return nil
        }
#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
#endif
        startRuntimeUsingHeadlessWindowIfNeeded(reason: reason)
        let liveSurface = liveSurfaceForGhosttyAccess(reason: reason)
#if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
        logDebugEvent(
            "surface.read_start surface=\(id.uuidString.prefix(8)) " +
            "ready=\(liveSurface != nil ? 1 : 0) headless=\(headlessStartupWindow != nil ? 1 : 0) " +
            "ms=\(String(format: "%.2f", elapsedMs))"
        )
#endif
        return liveSurface
    }

    /// Returns the filesystem work needed before an immediate socket-read surface creation.
    ///
    /// The caller runs the returned install work off the main actor, then records
    /// it with ``finishClaudeCommandShimInstallForSocketRead(_:)`` before calling
    /// ``liveSurfaceForSocketRead(reason:)``.
    ///
    /// - Returns: The wrapper URL, surface id, and temporary directory for the shim install.
    @MainActor
    public func claudeCommandShimInstallRequestForSocketRead() -> (
        wrapperURL: URL,
        surfaceId: UUID,
        temporaryDirectory: URL
    )? {
        guard !claudeCommandShimInstallCompleted else { return nil }
        guard let wrapperURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-claude-wrapper") else {
            claudeCommandShimInstallCompleted = true
            return nil
        }
        return (wrapperURL, id, FileManager.default.temporaryDirectory)
    }

    /// Records a socket-read shim install that was performed off the main actor.
    ///
    /// - Parameter shim: The installed shim descriptor, or `nil` when no executable wrapper exists.
    @MainActor
    public func finishClaudeCommandShimInstallForSocketRead(_ shim: ClaudeCommandShim?) {
        guard !claudeCommandShimInstallCompleted else { return }
        claudeCommandShimInstallTask?.cancel()
        claudeCommandShimInstallTask = nil
        claudeCommandShim = shim
        claudeCommandShimInstallCompleted = true
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
        closeHeadlessStartupWindowIfNeeded()

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
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
            teeLease?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
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
            // The teardown coordinator releases callbackContext; teeLease is not
            // transported through the request, so release it here.
            teeLease?.release()
            return
        }
#endif

        Task { @MainActor in
            // Keep free behavior aligned with deinit: perform the runtime teardown on
            // the next main-actor turn so SIGHUP delivery is deterministic but non-reentrant.
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            teeLease?.release()
        }
    }

    /// Frees the runtime surface while keeping the model alive for an
    /// agent-hibernation resume.
    @MainActor
    public func suspendRuntimeSurfaceForAgentHibernation(reason: String) {
        runtimeSurfaceSuspendedForAgentHibernation = true
        backgroundSurfaceStartQueued = false
        closeHeadlessStartupWindowIfNeeded()
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
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
            // The teardown coordinator releases callbackContext; teeLease is not
            // transported through the request, so release it here.
            teeLease?.release()
            return
        }
#endif

        Task { @MainActor in
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
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

    // Socket/API operations are an explicit runtime demand: they must be able to
    // start a terminal in a background workspace without selecting that workspace.
    // When there is no real window yet, bootstrap Ghostty in a hidden window and
    // reconcile display/window state when the terminal is later presented.
    //
    // Isolation note: the legacy entry accepted off-main callers with a
    // Thread.isMainThread check; every caller (Workspace, AppDelegate,
    // TabManager, and the surface's own send paths) runs on the main actor, so
    // the method is now @MainActor and the deferral hop uses a main-actor Task
    // (same executor, same next-turn semantics as the legacy
    // DispatchQueue.main.async).
    @MainActor
    public func requestBackgroundSurfaceStartIfNeeded() {
        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }
        guard !backgroundSurfaceStartQueued else { return }
        backgroundSurfaceStartQueued = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.backgroundSurfaceStartQueued = false
            guard self.allowsRuntimeSurfaceCreation() else { return }
            guard self.surface == nil else { return }
        #if DEBUG
            let startedAt = ProcessInfo.processInfo.systemUptime
        #endif
            if let view = self.attachedView, view.window != nil {
                self.createSurface(for: view)
            } else {
                self.scheduleHeadlessRuntimeStartIfNeeded(reason: "background-input")
            }
        #if DEBUG
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
            let view = self.attachedView ?? self.surfaceView
            logDebugEvent(
                "surface.background_start surface=\(self.id.uuidString.prefix(8)) inWindow=\(view.window != nil ? 1 : 0) ready=\(self.surface != nil ? 1 : 0) ms=\(String(format: "%.2f", elapsedMs))"
            )
        #endif
        }
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
        // Ghostty's vsync-driven renderer depends on having a valid display id; if it is missing
        // or stale, the surface can appear visually frozen until a focus/visibility change.
        // SwiftUI also re-enters this path for ordinary state propagation (drag hover, active
        // markers, visibility flags), so avoid forcing a geometry refresh when the attachment
        // itself is unchanged.
        if attachedView === view && surface != nil {
            releaseHeadlessStartupWindowIfNeeded(for: view)
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
            createSurface(for: view)
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
    private func claudeCommandShimStateForSurface(view: any TerminalSurfaceNativeViewing) -> (isReady: Bool, shim: ClaudeCommandShim?) {
        guard let wrapperURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-claude-wrapper") else {
            claudeCommandShimInstallCompleted = true
            return (true, nil)
        }

        if claudeCommandShimInstallCompleted {
            return (true, claudeCommandShim)
        }

        if claudeCommandShimInstallTask == nil {
            let surfaceId = id
            // Explicit captures and arguments: the region-based isolation
            // checker cannot analyze the legacy closure's implicit captures
            // and in-closure default-argument evaluation (same effective body).
            let temporaryDirectory = FileManager.default.temporaryDirectory
            let installOperation: @Sendable () async -> ClaudeCommandShim? = { [wrapperURL, surfaceId, temporaryDirectory] in
                TerminalSurface.installClaudeCommandShimIfPossible(
                    wrapperURL: wrapperURL,
                    surfaceId: surfaceId,
                    temporaryDirectory: temporaryDirectory,
                    fileManager: .default
                )
            }
            let installTask = Task.detached(priority: .utility, operation: installOperation)
            claudeCommandShimInstallTask = installTask
            Task { @MainActor [weak self, weak view] in
                let shim = await installTask.value
                guard let self else { return }
                self.claudeCommandShim = shim
                self.claudeCommandShimInstallCompleted = true
                self.claudeCommandShimInstallTask = nil
                guard self.allowsRuntimeSurfaceCreation(), self.surface == nil else { return }
                if let view, view.window != nil {
                    self.createSurface(for: view)
                } else if let attachedView = self.attachedView, attachedView.window != nil {
                    self.createSurface(for: attachedView)
                } else {
                    self.scheduleHeadlessRuntimeStartIfNeeded(reason: "claude-shim-ready")
                }
            }
        }

        return (false, nil)
    }

    @MainActor
    func createSurface(for view: any TerminalSurfaceNativeViewing) {
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
        let claudeShimState = claudeCommandShimStateForSurface(view: view)
        guard claudeShimState.isReady else { return }
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

        var baseConfig = configTemplate ?? CmuxSurfaceConfigTemplate()
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.font_size = baseConfig.fontSize
        surfaceConfig.wait_after_command = baseConfig.waitAfterCommand
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view as NSView).toOpaque()
        ))
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(surfaceHost: view, surfaceController: self))
        surfaceConfig.userdata = callbackContext.toOpaque()
        surfaceCallbackContext?.release()
        surfaceCallbackContext = callbackContext
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
#if DEBUG
        let templateFontText = String(format: "%.2f", surfaceConfig.font_size)
        logDebugEvent(
            "zoom.create surface=\(id.uuidString.prefix(5)) context=\(GhosttySurfaceRuntimeProbe.contextName(surfaceContext)) " +
            "templateFont=\(templateFontText)"
        )
#endif
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        var env = baseConfig.environmentVariables

        var protectedStartupEnvironmentKeys: Set<String> = []
        Self.applyManagedTerminalIdentityEnvironment(
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        func setManagedEnvironmentValue(_ key: String, _ value: String) {
            env[key] = value
            protectedStartupEnvironmentKeys.insert(key)
        }

        let socketPath = spawnPolicyProvider.controlSocketPath()
        Self.applyManagedCmuxContextEnvironment(
            Self.cmuxContextEnvironment(
                workspaceId: tabId,
                surfaceId: id,
                socketPath: socketPath
            ),
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        setManagedEnvironmentValue("CMUX_SOCKET", "")
        if let inheritedClaudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !inheritedClaudeConfigDir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(inheritedClaudeConfigDir)
        }
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
           FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) {
            setManagedEnvironmentValue("CMUX_BUNDLED_CLI_PATH", bundledCLIURL.path)
        }
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            setManagedEnvironmentValue("CMUX_BUNDLE_ID", bundleId)
        }

        // Port range for this workspace (base/range snapshotted once per app session)
        do {
            let startPort = sessionPortBase + portOrdinal * sessionPortRangeSize
            setManagedEnvironmentValue("CMUX_PORT", String(startPort))
            setManagedEnvironmentValue("CMUX_PORT_END", String(startPort + sessionPortRangeSize - 1))
            setManagedEnvironmentValue("CMUX_PORT_RANGE", String(sessionPortRangeSize))
        }

        // One synchronous snapshot at the same point the legacy code read the
        // individual settings stores.
        let spawnPolicy = spawnPolicyProvider.currentSpawnPolicy()
        let claudeHooksEnabled = spawnPolicy.claudeHooksEnabled
        if !claudeHooksEnabled {
            setManagedEnvironmentValue("CMUX_CLAUDE_HOOKS_DISABLED", "1")
        }
        if let customClaudePath = spawnPolicy.customClaudePath {
            setManagedEnvironmentValue("CMUX_CUSTOM_CLAUDE_PATH", customClaudePath)
        }
        setManagedEnvironmentValue(
            spawnPolicy.subagentNotificationEnvironmentKey,
            spawnPolicy.suppressSubagentNotifications ? "1" : "0"
        )
        if !spawnPolicy.cursorHooksEnabled {
            setManagedEnvironmentValue("CMUX_CURSOR_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.geminiHooksEnabled {
            setManagedEnvironmentValue("CMUX_GEMINI_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.kiroHooksEnabled {
            setManagedEnvironmentValue("CMUX_KIRO_HOOKS_DISABLED", "1")
        }
        setManagedEnvironmentValue("CMUX_KIRO_NOTIFICATION_LEVEL", spawnPolicy.kiroNotificationLevel)
        if !spawnPolicy.ampHooksEnabled {
            setManagedEnvironmentValue("CMUX_AMP_HOOKS_DISABLED", "1")
        }

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                setManagedEnvironmentValue(
                    "PATH",
                    Self.pathByPrependingUniqueDirectory(cliBinPath, to: currentPath)
                )
            }
        }

        if let claudeShim {
            setManagedEnvironmentValue("CMUX_CLAUDE_WRAPPER_SHIM", claudeShim.executablePath)
            setManagedEnvironmentValue("CMUX_CLAUDE_WRAPPER_SHIM_ROOT", claudeShim.directoryPath)
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            setManagedEnvironmentValue(
                "PATH",
                Self.pathByPrependingUniqueDirectory(claudeShim.directoryPath, to: currentPath)
            )
        }

        // Shell integration: inject startup wrappers for supported shells; skipped when the bundled dir is missing (deleted app bundle), see shellIntegrationDirectoryExists.
        if spawnPolicy.shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path,
           Self.shellIntegrationDirectoryExists(integrationDir) {
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION", "1")
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION_DIR", integrationDir)
            Self.applyManagedGitWatchEnvironment(
                watchGitStatusEnabled: spawnPolicy.watchGitStatusEnabled,
                showPullRequestsEnabled: spawnPolicy.showPullRequestsEnabled,
                to: &env,
                protectedKeys: &protectedStartupEnvironmentKeys
            )

            let shell = (env["SHELL"]?.isEmpty == false ? env["SHELL"] : nil)
                ?? getenv("SHELL").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            if let command = Self.applyManagedShellSpecificStartupEnvironment(
                shell: shell,
                integrationDir: integrationDir,
                userGhosttyShellIntegrationMode: engine.userGhosttyShellIntegrationMode,
                to: &env,
                protectedKeys: &protectedStartupEnvironmentKeys
            ) {
                if baseConfig.command?.isEmpty != false { baseConfig.command = command }
            }
        }
        env = Self.mergedStartupEnvironment(
            base: env,
            protectedKeys: protectedStartupEnvironmentKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )
        env["CMUX_SOCKET"] = ""

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createSurface = { [self] in
            if !envVars.isEmpty {
                let envVarsCount = envVars.count
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envVarsCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        let resolvedWorkingDirectory: String? = {
            if let workingDirectory, !workingDirectory.isEmpty {
                return workingDirectory
            }
            return baseConfig.workingDirectory
        }()
        let resolvedCommand: String? = {
            if let initialCommand, !initialCommand.isEmpty {
                return initialCommand
            }
            return baseConfig.command
        }()
        let runtimeInitialInput = nextRuntimeInitialInput
        let resolvedInitialInput: String? = {
            if let runtimeInitialInput, !runtimeInitialInput.isEmpty {
                return runtimeInitialInput
            }
            if let initialInput, !initialInput.isEmpty {
                return initialInput
            }
            return baseConfig.initialInput
        }()
        func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            guard let value else {
                return body(nil)
            }
            return value.withCString(body)
        }

        let createWithCommandAndWorkingDirectory = {
            withOptionalCString(resolvedCommand) { cCommand in
                surfaceConfig.command = cCommand
                withOptionalCString(resolvedWorkingDirectory) { cWorkingDir in
                    surfaceConfig.working_directory = cWorkingDir
                    withOptionalCString(resolvedInitialInput) { cInitialInput in
                        surfaceConfig.initial_input = cInitialInput
                        createSurface()
                    }
                }
            }
        }

        createWithCommandAndWorkingDirectory()

        if surface == nil {
            surfaceCallbackContext?.release()
            surfaceCallbackContext = nil
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
        registry.registerRuntimeSurface(createdSurface, ownerId: id)
        // A freshly created runtime surface always owns a live (non-defunct)
        // swap chain, so it is realized. Reset the flag in case this object's
        // previous runtime surface had been released before being freed (e.g.
        // agent-hibernation suspend/restore), which would otherwise let a later
        // realizeRenderer() double-realize and trip Ghostty's defunct assert.
        rendererRealized = true
        recordRuntimeSurfaceCreation()
        // Install the PTY tee so MobileTerminalByteTee receives every byte
        // the read thread produces, in order, before the VT parser runs.
        // Paired iPhones consume these bytes via `terminal.bytes` events
        // and feed them into their own libghostty surface, guaranteeing
        // grid parity by construction. The lease is released alongside
        // `surfaceCallbackContext` when the surface tears down.
        mobileByteTeeLease?.release()
        mobileByteTeeLease = byteTee.installTee(on: createdSurface, surfaceID: id)
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

        // Some GhosttyKit builds can drop inherited font_size during post-create
        // config/scale reconciliation. If runtime points don't match the inherited
        // template points, re-apply via binding action so all creation paths
        // (new surface, split, new workspace) preserve zoom from the source terminal.
        if let inheritedFontPoints = configTemplate?.fontSize,
           inheritedFontPoints > 0 {
            let currentFontPoints = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(createdSurface)
            let shouldReapply = {
                guard let currentFontPoints else { return true }
                return abs(currentFontPoints - inheritedFontPoints) > 0.05
            }()
            if shouldReapply {
                let action = String(format: "set_font_size:%.3f", inheritedFontPoints)
                _ = performBindingAction(action)
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
