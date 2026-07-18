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
    private let permissionService: ComputerUsePermissionService
    private let legacyHelperCleanupService: ComputerUseLegacyHelperCleanupService
    private let userDefaults: UserDefaults
    private let workspaceTitle: @MainActor (UUID) -> String?
    private let featureEnabled: @MainActor () -> Bool

    private var menuBarController: ComputerUseMenuBarController?
    private var cursorOverlayController: ComputerUseCursorOverlayController?
    private var watchTargetController: ComputerUseWatchTargetController?
    private var onboardingWindowController: ComputerUseOnboardingWindowController?
    private var enabledSettingTask: Task<Void, Never>?
    private var toolInvocationTask: Task<Void, Never>?
    private var legacyHelperCleanupTask: Task<Void, Never>?

    init(
        liveAgentIndex: SharedLiveAgentIndex,
        stateRepository: ComputerUseStateRepository,
        stateDirectoryURL: URL,
        configStore: JSONConfigStore,
        enabledKey: JSONKey<Bool>,
        showInMenuBarKey: JSONKey<Bool>,
        liveSettingRepository: ComputerUseLiveSettingRepository,
        permissionService: ComputerUsePermissionService,
        legacyHelperCleanupService: ComputerUseLegacyHelperCleanupService = ComputerUseLegacyHelperCleanupService(),
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
        self.legacyHelperCleanupService = legacyHelperCleanupService
        self.userDefaults = userDefaults
        self.workspaceTitle = workspaceTitle
        self.featureEnabled = featureEnabled
    }

    deinit {
        enabledSettingTask?.cancel()
        toolInvocationTask?.cancel()
        legacyHelperCleanupTask?.cancel()
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

        legacyHelperCleanupTask = Task { [legacyHelperCleanupService] in
            await legacyHelperCleanupService.cleanup()
        }

        let initialComputerUseEnabled = configStore.snapshotValue(for: enabledKey)
        enabledSettingTask = Task { [configStore, enabledKey, liveSettingRepository] in
            await liveSettingRepository.setEnabled(initialComputerUseEnabled)
            for await enabled in configStore.values(for: enabledKey) {
                guard !Task.isCancelled else { return }
                await liveSettingRepository.setEnabled(enabled)
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

        // Starting or restoring a supported agent stays quiet. The hook event
        // above presents setup only when that agent first invokes a Computer Use
        // MCP tool, or the user explicitly launches setup from Settings.
    }

    func teardown() {
        toolInvocationTask?.cancel()
        toolInvocationTask = nil
        cursorOverlayController?.stop()
        cursorOverlayController = nil
        watchTargetController?.stop()
        watchTargetController = nil
    }

    func presentOnboarding(startsAtPermissionStep: Bool = false) {
        userDefaults.set(true, forKey: ComputerUseOnboardingWindowController.seenDefaultsKey)
        let controller = onboardingWindowController ?? ComputerUseOnboardingWindowController(
            permissionService: permissionService
        )
        onboardingWindowController = controller
        controller.present(startsAtPermissionStep: startsAtPermissionStep)
    }

    private func recordToolInvocation(_ event: WorkstreamEvent) {
        guard Self.isComputerUseToolInvocation(event) else { return }
        let status = permissionService.status()
        let shouldPresent = ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: userDefaults.bool(forKey: ComputerUseOnboardingWindowController.seenDefaultsKey),
            featureEnabled: featureEnabled(),
            accessibilityGranted: status.accessibility,
            screenRecordingGranted: status.screenRecording
        )
        guard shouldPresent else { return }
        presentOnboarding(startsAtPermissionStep: true)
    }
}
