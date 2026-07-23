import AppKit
import CMUXAgentLaunch
import CmuxSettings

/// Owns the app-level computer-use menu-bar and onboarding controllers.
@MainActor
final class ComputerUseUXCoordinator {
    private let liveAgentIndex: SharedLiveAgentIndex
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

    private var menuBarController: ComputerUseMenuBarController?
    private var watchTargetController: ComputerUseWatchTargetController?
    private var onboardingWindowController: ComputerUseOnboardingWindowController?
    private var enabledSettingTask: Task<Void, Never>?
    private var toolInvocationTask: Task<Void, Never>?
    private var onboardingGateTask: Task<Void, Never>?

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
        self.liveAgentIndex = liveAgentIndex
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
        return toolName.hasPrefix("mcp__cmux-computer-use__")
            || toolName.hasPrefix("mcp__cmux_computer_use__")
            || toolName.hasPrefix("cmux-computer-use.")
            || toolName.hasPrefix("cmux_computer_use.")
    }

    func install(onFocusTerminal: @escaping @MainActor (UUID, UUID) -> Void) {
        guard menuBarController == nil else { return }

        let initialComputerUseEnabled = configStore.snapshotValue(for: enabledKey)
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
                self?.recordToolInvocation(event)
            }
        }

        // Automatic target following and explicit menu presentation share one
        // controller, so background/view mode cannot drift between entrypoints.
        let watchTarget = ComputerUseWatchTargetController(
            stateDirectoryURL: stateDirectoryURL,
            featureEnabled: featureEnabled,
            liveDriverSessions: { [liveAgentIndex] in
                (liveAgentIndex.index?.liveEntries() ?? []).reduce(into: [
                    String: ComputerUseLiveDriverSession
                ]()) { sessions, pair in
                    let driverSessionID =
                        ComputerUseSessionScope.driverSessionID(
                            surfaceID: pair.panelKey.panelId
                        )
                    sessions[driverSessionID] = ComputerUseLiveDriverSession(
                        workspaceID: pair.panelKey.workspaceId,
                        surfaceID: pair.panelKey.panelId,
                        entry: pair.entry
                    )
                }
            },
            currentLiveDriverSession: { [liveAgentIndex] scannedSession in
                guard
                    let entry = liveAgentIndex.index?.exactEntry(
                        workspaceId: scannedSession.workspaceID,
                        panelId: scannedSession.surfaceID
                    )
                else {
                    return nil
                }
                return ComputerUseLiveDriverSession(
                    workspaceID: scannedSession.workspaceID,
                    surfaceID: scannedSession.surfaceID,
                    entry: entry
                )
            },
            feed: ComputerUseWatchTargetFeed(
                authenticationKey: runtimeService.stateAuthenticationKey
            )
        )

        let snapshotStore = ComputerUseMenuBarSnapshotStore(
            liveAgentIndex: liveAgentIndex,
            stateRepository: stateRepository,
            stateDirectoryURL: stateDirectoryURL,
            configStore: configStore,
            showInMenuBarKey: showInMenuBarKey,
            workspaceTitle: workspaceTitle,
            featureEnabled: featureEnabled
        )
        menuBarController = ComputerUseMenuBarController(
            snapshotStore: snapshotStore,
            isRunningInBackground: { driverSessionID, logicalSessionID in
                watchTarget.isRunningInBackground(
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID
                )
            },
            onContinueInBackground: {
                workspaceID,
                surfaceID,
                driverSessionID,
                logicalSessionID,
                stateWriterIdentity in
                guard watchTarget.continueInBackground(
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID,
                    stateWriterIdentity: stateWriterIdentity
                ) else {
                    return false
                }
                onFocusTerminal(workspaceID, surfaceID)
                return true
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
                stateWriterIdentity in
                watchTarget.viewTarget(
                    identity,
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID,
                    stateWriterIdentity: stateWriterIdentity
                )
            },
            onStopComputerUse: {
                driverSessionID,
                logicalSessionID,
                stateWriterIdentity in
                guard watchTarget.canControlSession(
                    driverSessionID: driverSessionID,
                    logicalSessionID: logicalSessionID,
                    stateWriterIdentity: stateWriterIdentity
                ) else {
                    return
                }
                Task { @MainActor [runtimeService = self.runtimeService] in
                    _ = await runtimeService.endDriverSession(driverSessionID)
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
        watchTargetController?.stop()
        watchTargetController = nil
        onboardingWindowController?.dismiss()
        onboardingWindowController = nil
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
            runtimeService: runtimeService
        )
        onboardingWindowController = controller
        controller.present(startingAt: startingPoint)
    }

    private func recordToolInvocation(_ event: WorkstreamEvent) {
        guard Self.isComputerUseToolInvocation(event) else { return }
        guard onboardingGateTask == nil else { return }
        onboardingGateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { onboardingGateTask = nil }
            let enabled = featureEnabled()
            if enabled {
                // A real tool invocation is the authority to finish any
                // in-flight startup recovery before reading permission state.
                // This also serializes behind the launch-time reconciliation,
                // so a fast agent call cannot mistake a healthy helper for an
                // unknown one and reopen completed onboarding.
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
                screenRecordingGranted: status.screenRecording
            )
            guard shouldPresent else { return }
            guard onboardingWindowController?.isVisible != true else { return }
            presentOnboarding()
        }
    }
}
