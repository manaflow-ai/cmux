import AppKit
import CMUXAgentLaunch
import CmuxSettings

/// Owns the app-level computer-use menu-bar and onboarding controllers.
@MainActor
final class ComputerUseUXCoordinator {
    private let stateRepository: ComputerUseStateRepository
    private let stateDirectoryURL: URL
    private let configStore: JSONConfigStore
    private let enabledKey: JSONKey<Bool>
    private let showInMenuBarKey: JSONKey<Bool>
    private let liveSettingRepository: ComputerUseLiveSettingRepository
    private let runtimeService: ComputerUseRuntimeService
    private let userDefaults: UserDefaults
    private let workspaceTitle: @MainActor (UUID) -> String?
    private let featureEnabled: @MainActor () -> Bool
    private let liveSessionProjection: ComputerUseLiveSessionProjection
    private let activityLifecycle = ComputerUseActivityLifecycle()

    private var menuBarController: ComputerUseMenuBarController?
    private var menuBarSnapshotStore: ComputerUseMenuBarSnapshotStore?
    private var watchTargetController: ComputerUseWatchTargetController?
    private var onboardingWindowController: ComputerUseOnboardingWindowController?
    private var enabledSettingTask: Task<Void, Never>?
    private var toolInvocationTask: Task<Void, Never>?
    private var onboardingGateTask: Task<Void, Never>?
    /// Hook completion events can briefly race a live-index refresh. Retain
    /// the last accepted invocation identity so a matching Stop/SessionEnd can
    /// still retire the cursor during that bookkeeping gap without allowing a
    /// delayed event from a replaced agent generation to hide its successor.
    private var acceptedInvocationByDriverSessionID:
        [String: (
            surfaceID: UUID,
            agentSessionID: String,
            receivedAt: Date
        )] = [:]

    init(
        liveAgentIndex: SharedLiveAgentIndex,
        stateRepository: ComputerUseStateRepository,
        stateDirectoryURL: URL,
        configStore: JSONConfigStore,
        enabledKey: JSONKey<Bool>,
        showInMenuBarKey: JSONKey<Bool>,
        liveSettingRepository: ComputerUseLiveSettingRepository,
        runtimeService: ComputerUseRuntimeService,
        userDefaults: UserDefaults,
        workspaceTitle: @escaping @MainActor (UUID) -> String?,
        featureEnabled: @escaping @MainActor () -> Bool
    ) {
        self.stateRepository = stateRepository
        self.stateDirectoryURL = stateDirectoryURL
        self.configStore = configStore
        self.enabledKey = enabledKey
        self.showInMenuBarKey = showInMenuBarKey
        self.liveSettingRepository = liveSettingRepository
        self.runtimeService = runtimeService
        self.userDefaults = userDefaults
        self.workspaceTitle = workspaceTitle
        self.featureEnabled = featureEnabled
        self.liveSessionProjection = ComputerUseLiveSessionProjection(
            liveAgentIndex: liveAgentIndex
        )
        runtimeService.helperBuildReplacedHandler = { [userDefaults] in
            ComputerUseOnboardingWindowController.invalidateDirectCaptureReady(
                in: userDefaults
            )
        }
    }

    deinit {
        enabledSettingTask?.cancel()
        toolInvocationTask?.cancel()
        onboardingGateTask?.cancel()
    }

    static func isComputerUseToolInvocation(_ event: WorkstreamEvent) -> Bool {
        guard event.hookEventName == .preToolUse,
              let toolName = event.toolName?.lowercased()
        else {
            return false
        }
        // Accept the canonical MCP server spelling and the separator variants
        // emitted by different MCP clients. There is one cmux-cua contract;
        // legacy driver/server names are intentionally not recognized.
        return toolName.hasPrefix("mcp__cmux-cua__")
            || toolName.hasPrefix("mcp__cmux_cua__")
            || toolName.hasPrefix("cmux-cua.")
            || toolName.hasPrefix("cmux_cua.")
    }

    static func shouldReconcileToolInvocation(
        featureEnabled: Bool,
        settingEnabled: Bool
    ) -> Bool {
        featureEnabled && settingEnabled
    }

    func install(
        onFocusTerminal:
            @escaping ComputerUseSessionPresentationController
                .TerminalFocusEffect
    ) {
        guard menuBarController == nil else { return }

        let initialComputerUseEnabled = configStore.snapshotValue(for: enabledKey)
        runtimeService.setInitialOnboardingCompletion(
            userDefaults.bool(
                forKey: ComputerUseOnboardingWindowController
                    .directCaptureReadyDefaultsKey
            )
        )
        enabledSettingTask = Task { [configStore, enabledKey, liveSettingRepository, runtimeService] in
            await liveSettingRepository.setEnabled(initialComputerUseEnabled)
            await runtimeService.setEnabled(initialComputerUseEnabled)
            for await enabled in configStore.values(for: enabledKey) {
                guard !Task.isCancelled else { return }
                await liveSettingRepository.setEnabled(enabled)
                await runtimeService.setEnabled(enabled)
            }
        }

        toolInvocationTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: .workstreamEventReceived
            ) {
                guard !Task.isCancelled else { return }
                guard let event = notification.object as? WorkstreamEvent else { continue }
                self?.handleWorkstreamEvent(event)
            }
        }

        // Automatic target following and explicit menu presentation share one
        // controller, so background/view mode cannot drift between entrypoints.
        let watchTarget = ComputerUseWatchTargetController(
            stateDirectoryURL: stateDirectoryURL,
            featureEnabled: featureEnabled,
            liveDriverSessions: { [liveSessionProjection] in
                liveSessionProjection.sessionsByDriverSessionID()
            },
            currentLiveDriverSession: { [liveSessionProjection] scannedSession in
                liveSessionProjection.currentSession(matching: scannedSession)
            },
            feed: ComputerUseWatchTargetFeed(
                authenticationKey: runtimeService.stateAuthenticationKey
            ),
            onFocusTerminal: onFocusTerminal,
            onCursorVisibilityChange: {
                [runtimeService]
                driverSessionID,
                proxySessionID,
                visible,
                isCurrent in
                _ = await runtimeService.setDriverCursorVisible(
                    visible,
                    driverSessionID: driverSessionID,
                    proxySessionID: proxySessionID,
                    while: isCurrent
                )
            },
            onCursorReassert: {
                [runtimeService]
                driverSessionID,
                proxySessionID,
                targetWindowID,
                isCurrent in
                guard let targetWindowID else { return }
                _ = await runtimeService.reassertDriverCursor(
                    driverSessionID: driverSessionID,
                    proxySessionID: proxySessionID,
                    targetWindowID: targetWindowID,
                    while: isCurrent
                )
            }
        )

        let snapshotStore = ComputerUseMenuBarSnapshotStore(
            liveSessionProjection: liveSessionProjection,
            activityLifecycle: activityLifecycle,
            stateRepository: stateRepository,
            stateDirectoryURL: stateDirectoryURL,
            configStore: configStore,
            showInMenuBarKey: showInMenuBarKey,
            workspaceTitle: workspaceTitle,
            featureEnabled: featureEnabled
        )
        menuBarSnapshotStore = snapshotStore
        menuBarController = ComputerUseMenuBarController(
            snapshotStore: snapshotStore,
            isRunningInBackground: { driverSessionID, logicalSessionID in
                watchTarget.isRunningInBackground(
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID
                )
            },
            onContinueInBackground: {
                _,
                _,
                driverSessionID,
                logicalSessionID,
                stateWriterIdentity,
                proxySessionID in
                watchTarget.continueInBackground(
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID,
                    stateWriterIdentity: stateWriterIdentity,
                    proxySessionID: proxySessionID
                )
            },
            canViewComputerUse: {
                identity,
                driverSessionID,
                logicalSessionID,
                stateWriterIdentity in
                watchTarget.canViewTarget(
                    identity,
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID,
                    stateWriterIdentity: stateWriterIdentity
                )
            },
            onViewComputerUse: {
                identity,
                driverSessionID,
                logicalSessionID,
                stateWriterIdentity,
                proxySessionID in
                watchTarget.viewTarget(
                    identity,
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID,
                    stateWriterIdentity: stateWriterIdentity,
                    proxySessionID: proxySessionID
                )
            },
            onStopComputerUse: {
                driverSessionID,
                logicalSessionID,
                stateWriterIdentity,
                proxySessionID in
                guard watchTarget.canControlSession(
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID,
                    stateWriterIdentity: stateWriterIdentity
                ) else {
                    return
                }
                Task { @MainActor [runtimeService = self.runtimeService] in
                    _ = await runtimeService.endDriverSession(
                        driverSessionID,
                        proxySessionID: proxySessionID
                    )
                }
            },
            computerUseIcon: { [runtimeService = self.runtimeService] in
                runtimeService.presentationIcon
            }
        )

        // The standalone helper owns the native branded cursor and pins its
        // normal-level overlay directly above the driven target window. That
        // keeps foreground occluders above the cursor in background mode.
        // Starting the host-side feed renderer here would draw a second,
        // always-on-top cursor and break that window-relative ordering.

        // Bring the app the local driver is steering to the front (once per target)
        // so the user watches the automation instead of the cmux-hosted cursor
        // clicking on top of a hidden target. Gated the same way via `featureEnabled`.
        watchTarget.start()
        watchTargetController = watchTarget

        // Starting or restoring a supported agent stays quiet. The hook event
        // above presents setup only when that agent first invokes a Computer Use
        // MCP tool, or the user explicitly launches setup from Settings.
    }

    func teardown() {
        enabledSettingTask?.cancel()
        enabledSettingTask = nil
        toolInvocationTask?.cancel()
        toolInvocationTask = nil
        onboardingGateTask?.cancel()
        onboardingGateTask = nil
        menuBarController?.removeFromMenuBar()
        menuBarController = nil
        menuBarSnapshotStore = nil
        watchTargetController?.stop()
        watchTargetController = nil
        onboardingWindowController?.dismiss()
        onboardingWindowController = nil
        acceptedInvocationByDriverSessionID.removeAll()
    }

    func teardownForTermination() {
        teardown()
        runtimeService.stopForTermination()
    }

    func presentOnboarding(
        startingAt startingPoint: ComputerUseOnboardingWindowController.StartingPoint = .overview
    ) {
        userDefaults.set(true, forKey: ComputerUseOnboardingWindowController.seenDefaultsKey)
        let controller = onboardingWindowController ?? ComputerUseOnboardingWindowController(
            runtimeService: runtimeService,
            userDefaults: userDefaults
        )
        onboardingWindowController = controller
        controller.present(startingAt: startingPoint)
    }

    private func handleWorkstreamEvent(_ event: WorkstreamEvent) {
        let isComputerUseInvocation = Self.isComputerUseToolInvocation(event)
        if isComputerUseInvocation {
            reconcileToolInvocation(event)
        }
        let isCompletion =
            event.hookEventName == .stop
                || event.hookEventName == .sessionEnd
        guard isComputerUseInvocation || isCompletion else { return }
        let resolvedDriverSessionID = liveSessionProjection.driverSessionID(
                surfaceID: event.surfaceId,
                agentSessionID: event.sessionId,
                hookProcessID: event.ppid
            )
        let driverSessionID: String?
        if let resolvedDriverSessionID {
            driverSessionID = resolvedDriverSessionID
        } else if isCompletion,
                  let surfaceString = event.surfaceId,
                  let surfaceID = UUID(uuidString: surfaceString),
                  let candidate = acceptedInvocationByDriverSessionID.first(
                    where: {
                        $0.value.surfaceID == surfaceID
                            && $0.value.agentSessionID == event.sessionId
                            && event.receivedAt >= $0.value.receivedAt
                    }
                  )?.key {
            // The candidate was accepted for this exact surface + logical
            // agent session earlier in the run. This fallback only bridges a
            // transient projection refresh; a replaced generation has a
            // different agent session id and cannot match.
            driverSessionID = candidate
        } else {
            driverSessionID = nil
        }
        guard let driverSessionID else {
            return
        }

        switch event.hookEventName {
        case .preToolUse where isComputerUseInvocation:
            if let surfaceString = event.surfaceId,
               let surfaceID = UUID(uuidString: surfaceString) {
                acceptedInvocationByDriverSessionID[driverSessionID] = (
                    surfaceID,
                    event.sessionId,
                    event.receivedAt
                )
            }
            watchTargetController?.driverSessionDidStart(driverSessionID)
        case .stop, .sessionEnd:
            activityLifecycle.recordCompletion(
                driverSessionID: driverSessionID,
                receivedAt: event.receivedAt
            )
            let proxySessionID = menuBarSnapshotStore?.proxySessionID(
                for: driverSessionID
            )
            watchTargetController?.driverSessionDidComplete(
                driverSessionID,
                proxySessionID: proxySessionID
            )
            menuBarSnapshotStore?.driverSessionDidComplete(driverSessionID)
            acceptedInvocationByDriverSessionID.removeValue(
                forKey: driverSessionID
            )
        default:
            break
        }
    }

    private func reconcileToolInvocation(_ event: WorkstreamEvent) {
        guard onboardingGateTask == nil else { return }
        onboardingGateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { onboardingGateTask = nil }
            let enabled = Self.shouldReconcileToolInvocation(
                featureEnabled: featureEnabled(),
                settingEnabled: configStore.snapshotValue(for: enabledKey)
            )
            if enabled {
                // The persisted setting remains the authority. A real tool
                // invocation may only finish recovery while that setting is
                // still enabled; it must never override an explicit opt-out.
                await runtimeService.setEnabled(true)
            }
            let status = enabled
                ? await runtimeService.refreshHelperStatus()
                : runtimeService.status()
            let shouldPresent = ComputerUseOnboardingWindowController.shouldPresentAutomatically(
                seen: userDefaults.bool(forKey: ComputerUseOnboardingWindowController.seenDefaultsKey),
                featureEnabled: enabled,
                permissionStatusIsKnown: runtimeService.permissionStatusIsKnown,
                accessibilityGranted: status.accessibility,
                screenRecordingGranted: status.screenRecording,
                directCaptureReady: userDefaults.bool(
                    forKey: ComputerUseOnboardingWindowController.directCaptureReadyDefaultsKey
                )
            )
            guard shouldPresent else { return }
            guard onboardingWindowController?.isVisible != true else { return }
            presentOnboarding()
        }
    }
}
