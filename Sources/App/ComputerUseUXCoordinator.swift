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

        // One controller owns both automatic target following and the explicit
        // background/view switch, so every focus entrypoint shares one mode.
        let watchTarget = ComputerUseWatchTargetController(
            stateDirectoryURL: stateDirectoryURL,
            featureEnabled: featureEnabled
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
            isRunningInBackground: {
                watchTarget.isRunningInBackground
            },
            onContinueInBackground: { workspaceID, surfaceID in
                watchTarget.continueInBackground()
                onFocusTerminal(workspaceID, surfaceID)
            },
            canViewComputerUse: { identity in
                watchTarget.canViewTarget(identity)
            },
            onViewComputerUse: { identity in
                _ = watchTarget.viewTarget(identity)
            },
            onNoLiveSessions: {
                watchTarget.resetPresentationMode()
            }
        )

        // The standalone helper owns the native branded cursor. Starting the
        // host-side feed renderer here would draw a second cursor at the same
        // time and can leave the previous target visible during the next glide.

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
        toolInvocationTask?.cancel()
        toolInvocationTask = nil
        watchTargetController?.stop()
        watchTargetController = nil
    }

    func presentOnboarding() {
        userDefaults.set(true, forKey: ComputerUseOnboardingWindowController.seenDefaultsKey)
        let controller = onboardingWindowController ?? ComputerUseOnboardingWindowController(
            runtimeService: runtimeService
        )
        onboardingWindowController = controller
        controller.present()
    }

    private func recordToolInvocation(_ event: WorkstreamEvent) {
        guard Self.isComputerUseToolInvocation(event) else { return }
        guard onboardingGateTask == nil else { return }
        onboardingGateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { onboardingGateTask = nil }
            // Do not launch a helper status probe before onboarding. On an
            // ungranted Accessibility identity, even AXIsProcessTrusted() can
            // create a system warning and race the drag-to-grant flow.
            let status = runtimeService.status()
            let shouldPresent = ComputerUseOnboardingWindowController.shouldPresentAutomatically(
                seen: userDefaults.bool(forKey: ComputerUseOnboardingWindowController.seenDefaultsKey),
                featureEnabled: featureEnabled(),
                accessibilityGranted: status.accessibility,
                screenRecordingGranted: status.screenRecording
            )
            guard shouldPresent else { return }
            presentOnboarding()
        }
    }
}
