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
    private let liveAgentIndex: SharedLiveAgentIndex
    private let userDefaults: UserDefaults
    private let workspaceTitle: @MainActor (UUID) -> String?
    private let featureEnabled: @MainActor () -> Bool
    private let ownsSurface: @MainActor (UUID, UUID?) -> Bool
    private let liveSessionProjection: ComputerUseLiveSessionProjection
    private let activityLifecycle = ComputerUseActivityLifecycle()

    private var menuBarController: ComputerUseMenuBarController?
    private var menuBarSnapshotStore: ComputerUseMenuBarSnapshotStore?
    private var watchTargetController: ComputerUseWatchTargetController?
    private var onboardingWindowController: ComputerUseOnboardingWindowController?
    private var enabledSettingTask: Task<Void, Never>?
    private var toolInvocationTask: Task<Void, Never>?
    private var onboardingCoordinator: ComputerUseOnboardingCoordinator?
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
        featureEnabled: @escaping @MainActor () -> Bool,
        onboardingCoordinator: ComputerUseOnboardingCoordinator? = nil,
        ownsSurface: @escaping @MainActor (UUID, UUID?) -> Bool = { _, _ in false }
    ) {
        self.stateRepository = stateRepository
        self.stateDirectoryURL = stateDirectoryURL
        self.configStore = configStore
        self.enabledKey = enabledKey
        self.showInMenuBarKey = showInMenuBarKey
        self.liveSettingRepository = liveSettingRepository
        self.runtimeService = runtimeService
        self.liveAgentIndex = liveAgentIndex
        self.userDefaults = userDefaults
        self.workspaceTitle = workspaceTitle
        self.featureEnabled = featureEnabled
        self.ownsSurface = ownsSurface
        self.liveSessionProjection = ComputerUseLiveSessionProjection(
            liveAgentIndex: liveAgentIndex
        )
        self.onboardingCoordinator = onboardingCoordinator
    }

    deinit {
        enabledSettingTask?.cancel()
        toolInvocationTask?.cancel()
    }

    static func isComputerUseToolInvocation(_ event: WorkstreamEvent) -> Bool {
        computerUseToolName(event) != nil
    }

    private static func computerUseToolName(_ event: WorkstreamEvent) -> String? {
        guard event.hookEventName == .preToolUse,
              let toolName = event.toolName?.lowercased()
        else {
            return nil
        }
        // Accept the canonical MCP server spelling and the separator variants
        // emitted by different MCP clients. There is one cmux-cua contract;
        // legacy driver/server names are intentionally not recognized.
        for prefix in ["mcp__cmux-cua__", "mcp__cmux_cua__", "cmux-cua.", "cmux_cua."] {
            if toolName.hasPrefix(prefix) {
                let name = String(toolName.dropFirst(prefix.count))
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    func install(
        onFocusTerminal:
            @escaping ComputerUseSessionPresentationController
                .TerminalFocusEffect
    ) {
        guard menuBarController == nil else { return }

        _ = ensureOnboardingCoordinator()

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
                await self?.handleWorkstreamEvent(event)
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

        // Starting or restoring an agent stays quiet. Only its first functional
        // Computer Use invocation can request setup through the shared coordinator.
    }

    func teardown() {
        enabledSettingTask?.cancel()
        enabledSettingTask = nil
        toolInvocationTask?.cancel()
        toolInvocationTask = nil
        menuBarController?.removeFromMenuBar()
        menuBarController = nil
        menuBarSnapshotStore = nil
        watchTargetController?.stop()
        watchTargetController = nil
        onboardingWindowController?.dismiss()
        onboardingWindowController = nil
        onboardingCoordinator = nil
        acceptedInvocationByDriverSessionID.removeAll()
    }

    func teardownForTermination() {
        teardown()
        runtimeService.stopForTermination()
    }

    /// Explicit Settings actions can resume setup or select another permission
    /// step after automatic first-use presentation has been dismissed.
    @discardableResult
    func presentOnboardingFromSettings(
        startingAt startingPoint: ComputerUseOnboardingWindowController.StartingPoint = .overview
    ) -> Bool {
        ensureOnboardingCoordinator().requestFromSettings(startingAt: startingPoint)
    }

    private func presentOnboardingWindow(
        startingAt startingPoint: ComputerUseOnboardingWindowController.StartingPoint
    ) {
        userDefaults.set(true, forKey: ComputerUseOnboardingWindowController.seenDefaultsKey)
        let controller = onboardingWindowController ?? ComputerUseOnboardingWindowController(
            runtimeService: runtimeService
        )
        onboardingWindowController = controller
        controller.present(startingAt: startingPoint)
    }

    private func ensureOnboardingCoordinator() -> ComputerUseOnboardingCoordinator {
        if let onboardingCoordinator {
            return onboardingCoordinator
        }
        let coordinator = ComputerUseOnboardingCoordinator(
            presenter: { [weak self] startingPoint in
                self?.presentOnboardingWindow(startingAt: startingPoint)
            }
        )
        onboardingCoordinator = coordinator
        return coordinator
    }

    func handleWorkstreamEvent(_ event: WorkstreamEvent) async {
        let isComputerUseInvocation = Self.isComputerUseToolInvocation(event)
        let toolName = Self.computerUseToolName(event)
        let isCompletion =
            event.hookEventName == .stop
                || event.hookEventName == .sessionEnd
        guard isComputerUseInvocation || isCompletion else { return }
        let isFunctionalInvocation = isComputerUseInvocation
            && toolName != "check_permissions"
            && featureEnabled()
            && runtimeService.desiredEnabled
        let surfaceID = event.surfaceId.flatMap(UUID.init(uuidString:))
        let hasValidSurface = surfaceID != nil
        let ownsLocalSurface = surfaceID.map {
            ownsSurface($0, event.workspaceId.flatMap(UUID.init(uuidString:)))
        } == true
        if isComputerUseInvocation,
           toolName != "check_permissions",
           hasValidSurface,
           ownsLocalSurface,
           runtimeService.acceptsNewLaunches {
            // Authenticated hook ingress has already established ownership of a
            // live local terminal. Agent process indexing may lag the first
            // hook, so it is used only for session bookkeeping below.
            _ = ensureOnboardingCoordinator().requestFromToolInvocation(
                onboarding: runtimeService.onboarding
            )
            if !runtimeService.desiredEnabled {
                // An explicit functional request is the opt-in. Persist it
                // after presenting so the window is never delayed by config I/O.
                try? await configStore.set(true, for: enabledKey)
                await runtimeService.setEnabled(true)
            }
        }
        if isFunctionalInvocation,
           ownsLocalSurface,
           runtimeService.permissionPhase == .onboardingRequired {
            // A valid-surface hook may precede the initial agent-index scan.
            // Await its authoritative refresh before resolving the session.
            guard await liveAgentIndex.indexRefreshingNow() != nil,
                  !Task.isCancelled else { return }
        }
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

}
