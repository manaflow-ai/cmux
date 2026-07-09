internal import AppKit
internal import Foundation
internal import GhosttyKit
internal import CmuxTerminalCore
internal import Darwin
#if DEBUG
internal import CMUXDebugLog
#endif

extension TerminalSurface {
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
        let gateAction = spawnGateCreateAction(for: view, source: source)
        guard gateAction != .stop else { return }
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
        let spawnGrant: TerminalSurfaceSpawnGrant?
        let deniedSpawn: (message: String, request: TerminalSurfaceSpawnGateRequest, reason: String)?
        switch gateAction {
        case .proceed(let grant):
            spawnGrant = grant
            deniedSpawn = nil
        case .deny(let reason, let request):
            spawnGrant = nil
            let message = spawnGate?.deniedSpawnMessage(reason: reason) ?? reason
            deniedSpawn = (message, request, reason)
        case .stop:
            return
        }
        if let deniedSpawn {
            gateSpawnDenied(reason: deniedSpawn.reason, request: deniedSpawn.request)
        }

        let runtimeSurfaceCreation = createNativeRuntimeSurface(
            app: app,
            for: view,
            scaleFactors: scaleFactors,
            claudeShim: claudeShim,
            spawnGrant: spawnGrant,
            forceManualIO: deniedSpawn != nil
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
        rendererRealized = true
        recordRuntimeSurfaceCreation()
        mobileByteTeeLease?.release()
        if deniedSpawn == nil {
            mobileByteTeeLease = byteTee.installTee(on: createdSurface, surfaceID: id)
        } else {
            mobileByteTeeLease = nil
        }
        if runtimeInitialInput != nil {
            nextRuntimeInitialInput = nil
        }

        additionalEnvironment.removeValue(forKey: scrollbackReplayEnvironmentKey)

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

        flushPendingRemoteOutput(to: createdSurface)
        if let deniedSpawn {
            processRemoteOutput(Data((deniedSpawn.message + "\r\n").utf8))
        }

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
                _ = performBindingAction(action)
            }
        }

        ghostty_surface_set_focus(createdSurface, desiredFocusState)

        flushPendingSocketInputIfNeeded()

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

    @MainActor
    func resetSpawnGateStateForRuntimeTeardown() {
        spawnGateState = .idle
    }

    @MainActor
    private func spawnGateCreateAction(
        for view: any TerminalSurfaceNativeViewing,
        source: RuntimeSurfaceCreationSource
    ) -> TerminalSurfaceSpawnGateCreateAction {
        guard !manualIO, let gate = spawnGate else { return .proceed(nil) }
        switch spawnGateState {
        case .idle:
            guard gate.requiresGate() else { return .proceed(nil) }
            let request = spawnGateRequest(source: source)
            spawnGateState = .pending
            Task { @MainActor [weak self, weak view] in
                let resolution = await gate.resolveSpawn(request)
                guard let self else { return }
                guard case .pending = spawnGateState else { return }
                spawnGateState = .resolved(resolution)
                resumeSurfaceCreationAfterSpawnGateResolved(view: view, source: source)
            }
            return .stop
        case .pending:
            return .stop
        case .resolved(.proceed(let grant)):
            return .proceed(grant)
        case .resolved(.deny(let reason)):
            return .deny(reason: reason, request: spawnGateRequest(source: source))
        }
    }

    @MainActor
    private func spawnGateRequest(source: RuntimeSurfaceCreationSource) -> TerminalSurfaceSpawnGateRequest {
        let command = trimmedNonEmpty(initialCommand ?? configTemplate?.command)
        let cwd = trimmedNonEmpty(workingDirectory ?? configTemplate?.workingDirectory)
        let environment = Self.mergedNormalizedEnvironment(
            base: respawnAdditionalEnvironment,
            overrides: initialEnvironmentOverrides
        )
        return TerminalSurfaceSpawnGateRequest(
            command: command,
            workingDirectory: cwd,
            environmentAdditions: environment,
            surfaceId: id,
            workspaceId: tabId,
            source: String(describing: source),
            isRespawn: surface != nil || runtimeSurfaceCreatedAt != nil
        )
    }

    @MainActor
    private func resumeSurfaceCreationAfterSpawnGateResolved(
        view: (any TerminalSurfaceNativeViewing)?,
        source: RuntimeSurfaceCreationSource
    ) {
        guard allowsRuntimeSurfaceCreation(), surface == nil else { return }
        if let view, view.window != nil {
            createSurface(for: view, source: source)
        } else if let attachedView, attachedView.window != nil {
            createSurface(for: attachedView, source: source)
        } else {
            scheduleHeadlessRuntimeStartIfNeeded(reason: "spawn-gate-resolved", source: source)
        }
    }

    @MainActor
    private func gateSpawnDenied(reason: String, request: TerminalSurfaceSpawnGateRequest) {
        spawnGate?.spawnDenied(reason: reason, request: request)
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
