import AppKit
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
    private let permissionService: ComputerUsePermissionService
    private let userDefaults: UserDefaults
    private let workspaceTitle: @MainActor (UUID) -> String?
    private let featureEnabled: @MainActor () -> Bool

    private var menuBarController: ComputerUseMenuBarController?
    private var cursorOverlayController: ComputerUseCursorOverlayController?
    private var watchTargetController: ComputerUseWatchTargetController?
    private var onboardingWindowController: ComputerUseOnboardingWindowController?
    private var enabledSettingTask: Task<Void, Never>?
    private var agentSessionRequiresRestart = false

    init(
        liveAgentIndex: SharedLiveAgentIndex,
        stateRepository: ComputerUseStateRepository,
        stateDirectoryURL: URL,
        configStore: JSONConfigStore,
        enabledKey: JSONKey<Bool>,
        showInMenuBarKey: JSONKey<Bool>,
        liveSettingRepository: ComputerUseLiveSettingRepository,
        permissionService: ComputerUsePermissionService,
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
        self.permissionService = permissionService
        self.userDefaults = userDefaults
        self.workspaceTitle = workspaceTitle
        self.featureEnabled = featureEnabled
    }

    deinit {
        enabledSettingTask?.cancel()
    }

    func install(onFocusTerminal: @escaping @MainActor (UUID, UUID) -> Void) {
        guard menuBarController == nil else { return }

        let initialComputerUseEnabled = configStore.snapshotValue(for: enabledKey)
        enabledSettingTask = Task { [configStore, enabledKey, liveSettingRepository] in
            await liveSettingRepository.setEnabled(initialComputerUseEnabled)
            for await enabled in configStore.values(for: enabledKey) {
                guard !Task.isCancelled else { return }
                await liveSettingRepository.setEnabled(enabled)
            }
        }

        let snapshotStore = ComputerUseMenuBarSnapshotStore(
            liveAgentIndex: liveAgentIndex,
            stateRepository: stateRepository,
            stateDirectoryURL: stateDirectoryURL,
            configStore: configStore,
            showInMenuBarKey: showInMenuBarKey,
            workspaceTitle: workspaceTitle,
            featureEnabled: featureEnabled,
            onCapableSessionStarted: { [weak self] in
                self?.recordCapableSessionStarted()
            }
        )
        menuBarController = ComputerUseMenuBarController(
            snapshotStore: snapshotStore,
            onFocusTerminal: onFocusTerminal,
            canFocusTarget: { identity in
                guard let pid = pid_t(exactly: identity.processIdentifier) else { return false }
                return identity.matches(NSRunningApplication(processIdentifier: pid))
            },
            onFocusTarget: { identity in
                guard let pid = pid_t(exactly: identity.processIdentifier),
                      let application = NSRunningApplication(processIdentifier: pid),
                      identity.matches(application)
                else {
                    return
                }
                // NSRunningApplication.activate is unreliable at fronting another
                // app on macOS 14+; NSWorkspace.openApplication genuinely brings
                // the already-running target to the front.
                if let bundleURL = application.bundleURL {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.createsNewApplicationInstance = false
                    NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
                } else {
                    _ = application.activate(options: [.activateAllWindows])
                }
            }
        )

        // Render the branded, click-through cursor overlay whenever the local
        // driver is steering the pointer. Gated the same way as the menu bar via
        // `featureEnabled`; the controller hides itself when the feature is off.
        let cursorOverlay = ComputerUseCursorOverlayController(
            stateDirectoryURL: stateDirectoryURL,
            featureEnabled: featureEnabled
        )
        cursorOverlay.start()
        cursorOverlayController = cursorOverlay

        // Bring the app the local driver is steering to the front (once per target)
        // so the user watches the automation instead of the cmux-hosted cursor
        // clicking on top of a hidden target. Gated the same way via `featureEnabled`.
        let watchTarget = ComputerUseWatchTargetController(
            stateDirectoryURL: stateDirectoryURL,
            featureEnabled: featureEnabled
        )
        watchTarget.start()
        watchTargetController = watchTarget

        // Deliberately do NOT present onboarding at launch. Permission setup is
        // offered only when computer use is actually about to be used — the first
        // time a capable agent session starts (see recordCapableSessionStarted) —
        // or on demand from Settings > Computer Use. Launch stays quiet: nothing
        // prompts or pops a window until the user reaches one of those points.
    }

    func teardown() {
        cursorOverlayController?.stop()
        cursorOverlayController = nil
        watchTargetController?.stop()
        watchTargetController = nil
    }

    func presentOnboarding() {
        userDefaults.set(true, forKey: ComputerUseOnboardingWindowController.seenDefaultsKey)
        let controller = onboardingWindowController ?? ComputerUseOnboardingWindowController(
            permissionService: permissionService,
            agentSessionRequiresRestart: { [weak self] in
                self?.agentSessionRequiresRestart ?? false
            }
        )
        onboardingWindowController = controller
        controller.present()
    }

    private func recordCapableSessionStarted() {
        // Query the HELPER's own TCC identity (not cmux's) before deciding whether
        // a permission grant now requires restarting the helper session. The async
        // hop also defers the present off this synchronous menu-bar refresh, which
        // avoids reentering focus/first-responder handling with an inline key window.
        Task { [weak self] in
            guard let self else { return }
            let status = await permissionService.refreshHelperStatus()
            agentSessionRequiresRestart = !status.accessibility || !status.screenRecording
            presentOnboardingAutomaticallyIfNeeded()
        }
    }

    private func presentOnboardingAutomaticallyIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            // The helper owns the grants, so refresh from its identity out of
            // process before gating. The await also hops off the caller's stack.
            let status = await permissionService.refreshHelperStatus()
            let feature = featureEnabled()
            let should = ComputerUseOnboardingWindowController.shouldPresentAutomatically(
                seen: userDefaults.bool(forKey: ComputerUseOnboardingWindowController.seenDefaultsKey),
                featureEnabled: feature,
                accessibilityGranted: status.accessibility,
                screenRecordingGranted: status.screenRecording
            )
            NSLog("[cmux-computer-use] onboarding gate: feature=\(feature) accessibility=\(status.accessibility) screenRecording=\(status.screenRecording) present=\(should)")
            guard should else { return }
            presentOnboarding()
        }
    }
}
