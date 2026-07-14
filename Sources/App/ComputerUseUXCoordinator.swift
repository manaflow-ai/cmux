import AppKit
import CmuxSettings

/// Owns the app-level computer-use menu-bar and onboarding controllers.
@MainActor
final class ComputerUseUXCoordinator {
    static let shared = ComputerUseUXCoordinator()

    private var menuBarController: ComputerUseMenuBarController?
    private var onboardingWindowController: ComputerUseOnboardingWindowController?

    private init() {}

    func install(appDelegate: AppDelegate) {
        guard menuBarController == nil else { return }

        let catalog = SettingCatalog()
        let configStore = JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        let snapshotStore = ComputerUseMenuBarSnapshotStore(
            liveAgentIndex: SharedLiveAgentIndex.shared,
            stateRepository: ComputerUseStateRepository(),
            stateDirectoryURL: ComputerUseStateRepository.defaultStateDirectory(),
            configStore: configStore,
            showInMenuBarKey: catalog.computerUse.showInMenuBar,
            workspaceTitle: { [weak appDelegate] workspaceID in
                appDelegate?.tabTitle(for: workspaceID)
            },
            featureEnabled: {
                CmuxFeatureFlags.shared.isComputerUseUXEnabled
            },
            onCapableSessionStarted: { [weak self] in
                self?.presentOnboardingAutomaticallyIfNeeded()
            }
        )
        menuBarController = ComputerUseMenuBarController(
            snapshotStore: snapshotStore,
            onFocusTerminal: { [weak appDelegate] workspaceID, surfaceID in
                _ = appDelegate?.focusTerminal(tabId: workspaceID, surfaceId: surfaceID)
            },
            onFocusTarget: { targetPID in
                _ = NSRunningApplication(processIdentifier: targetPID)?.activate(options: [.activateAllWindows])
            }
        )
    }

    func presentOnboarding() {
        UserDefaults.standard.set(true, forKey: ComputerUseOnboardingWindowController.seenDefaultsKey)
        let controller = onboardingWindowController ?? ComputerUseOnboardingWindowController()
        onboardingWindowController = controller
        controller.present()
    }

    private func presentOnboardingAutomaticallyIfNeeded() {
        let permissions = ComputerUsePermissionService()
        guard ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: UserDefaults.standard.bool(forKey: ComputerUseOnboardingWindowController.seenDefaultsKey),
            featureEnabled: CmuxFeatureFlags.shared.isComputerUseUXEnabled,
            accessibilityGranted: permissions.accessibilityGranted(),
            screenRecordingGranted: permissions.screenRecordingGranted()
        ) else {
            return
        }
        presentOnboarding()
    }
}
