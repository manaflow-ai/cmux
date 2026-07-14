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
                _ = application.activate(options: [.activateAllWindows])
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

        // Offer permission setup at app startup so the embedded driver does not
        // have to be the first process to discover missing TCC grants.
        presentOnboardingAutomaticallyIfNeeded()
    }

    func teardown() {
        cursorOverlayController?.stop()
        cursorOverlayController = nil
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
        agentSessionRequiresRestart = !permissionService.accessibilityGranted()
            || !permissionService.screenRecordingGranted()
        presentOnboardingAutomaticallyIfNeeded()
    }

    private func presentOnboardingAutomaticallyIfNeeded() {
        let feature = featureEnabled()
        let ax = permissionService.accessibilityGranted()
        let screen = permissionService.screenRecordingGranted()
        let should = ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: userDefaults.bool(forKey: ComputerUseOnboardingWindowController.seenDefaultsKey),
            featureEnabled: feature,
            accessibilityGranted: ax,
            screenRecordingGranted: screen
        )
        NSLog("[cmux-computer-use] onboarding gate: feature=\(feature) accessibility=\(ax) screenRecording=\(screen) present=\(should)")
        guard should else { return }
        presentOnboarding()
    }
}
