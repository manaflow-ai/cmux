import AppKit
import Combine
import SwiftUI

struct ComputerUseOnboardingPermissionSnapshot: Equatable, Sendable {
    let statusIsKnown: Bool
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
}

@MainActor
final class ComputerUseOnboardingPresentationState: ObservableObject {
    @Published private(set) var returnToOverviewGeneration = 0
    @Published private(set) var permissionCompanionVisible = false
    @Published private(set) var permissionCompanionLayoutReady = false
    @Published private(set) var onboardingComplete = false
    /// True while the direct-capture probe can raise Tahoe's system consent
    /// alert, so whichever presentation is on screen explains that alert.
    @Published private(set) var screenCaptureConsentPending = false
    @Published private(set) var permissionSnapshot:
        ComputerUseOnboardingPermissionSnapshot?

    func publishPermissionSnapshot(
        statusIsKnown: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool
    ) {
        permissionSnapshot = ComputerUseOnboardingPermissionSnapshot(
            statusIsKnown: statusIsKnown,
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted
        )
    }

    func beginScreenCaptureConsent() {
        screenCaptureConsentPending = true
    }

    func endScreenCaptureConsent() {
        screenCaptureConsentPending = false
    }

    func showPermissionCompanion() {
        guard !permissionCompanionVisible else { return }
        onboardingComplete = false
        permissionCompanionLayoutReady = false
        permissionCompanionVisible = true
    }

    @discardableResult
    func markPermissionCompanionLayoutReady() -> Bool {
        guard permissionCompanionVisible, !permissionCompanionLayoutReady else {
            return false
        }
        permissionCompanionLayoutReady = true
        return true
    }

    @discardableResult
    func showCompletionInExpandedOnboarding() -> Bool {
        guard !screenCaptureConsentPending else { return false }
        onboardingComplete = true
        permissionCompanionVisible = false
        permissionCompanionLayoutReady = false
        return true
    }

    func requestExpandedPresentation(resetToOverview: Bool = true) {
        onboardingComplete = false
        permissionCompanionVisible = false
        permissionCompanionLayoutReady = false
        if resetToOverview {
            returnToOverviewGeneration &+= 1
        }
    }

    func requestReturnToOverview() {
        requestExpandedPresentation()
    }
}

/// Presents a fresh nonmodal computer-use onboarding window for each run.
@MainActor
final class ComputerUseOnboardingWindowController: NSObject, NSWindowDelegate {
    enum StartingPoint: Sendable, Equatable {
        case overview
        case accessibility
        case screenRecording

        var step: ComputerUseOnboardingStep {
            switch self {
            case .overview: .overview
            case .accessibility: .accessibility
            case .screenRecording: .screenRecording
            }
        }
    }

    static let seenDefaultsKey = "cmux.computerUse.onboarding.seen"
    static let directCaptureReadyDefaultsKey = "cmux.computerUse.directCapture.ready"

    /// Drops the cached direct-capture verification. Called when the installed
    /// helper build changes: Tahoe's consent is bound to the helper's code
    /// signature, so a stale `true` would keep onboarding away while the system
    /// alert fires at the next capture with no explanation on screen.
    static func invalidateDirectCaptureReady(in userDefaults: UserDefaults) {
        userDefaults.removeObject(forKey: directCaptureReadyDefaultsKey)
    }
    static let completionDismissDelay: Duration = .seconds(2.4)
    nonisolated static let permissionCompanionGlideDuration: TimeInterval = 0.48
    private static let expandedWindowSize = NSSize(width: 600, height: 440)
    nonisolated private static let permissionCompanionWindowSize =
        ComputerUsePermissionCompanionLayout.size
    private static let expandedWindowStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .fullSizeContentView,
    ]
    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    private var window: ComputerUseOnboardingWindow?
    private var permissionCompanionWindow: ComputerUseOnboardingWindow?
    private let runtimeService: ComputerUseRuntimeService
    private let userDefaults: UserDefaults
    private let permissionWindowPlacement = ComputerUseOnboardingWindowPlacement()
    private var systemSettingsActivationTask: Task<Void, Never>?
    private var systemSettingsPlacementRetryTask: Task<Void, Never>?
    private var systemSettingsTrackingTask: Task<Void, Never>?
    private var pendingPlacementRequestID: UUID?
    private var systemSettingsActivatedForPendingRequest = false
    private var pendingPermissionCompanionFrame: NSRect?
    private var pendingPermissionStep: ComputerUseOnboardingStep?
    private var presentationState: ComputerUseOnboardingPresentationState?
    private var completionDismissTask: Task<Void, Never>?

    init(
        runtimeService: ComputerUseRuntimeService,
        userDefaults: UserDefaults = .standard
    ) {
        self.runtimeService = runtimeService
        self.userDefaults = userDefaults
        super.init()
    }

    static func shouldPresentAutomatically(
        seen: Bool,
        featureEnabled: Bool,
        permissionStatusIsKnown: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        directCaptureReady: Bool
    ) -> Bool {
        featureEnabled
            && (
                !directCaptureReady
                    || (!seen && (
                        !permissionStatusIsKnown
                            || !(accessibilityGranted && screenRecordingGranted)
                    ))
            )
    }

    var isVisible: Bool {
        (window?.isVisible ?? false) || (permissionCompanionWindow?.isVisible ?? false)
    }

    func present(startingAt startingPoint: StartingPoint = .overview) {
        runtimeService.onboardingWasPresented()
        stopSystemSettingsObservation()
        completionDismissTask?.cancel()
        completionDismissTask = nil
        dismissPermissionCompanion()
        window?.close()
        let window = makeWindow(startingAt: startingPoint)
        self.window = window
        window.delegate = self
        observeSystemSettingsActivation()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces]
        window.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func makeWindow(startingAt startingPoint: StartingPoint = .overview) -> ComputerUseOnboardingWindow {
        let presentationState = ComputerUseOnboardingPresentationState()
        self.presentationState = presentationState
        let rootView = ComputerUseOnboardingView(
            runtimeService: runtimeService,
            presentationState: presentationState,
            initialStep: startingPoint.step,
            initialDirectCaptureReady: userDefaults.bool(
                forKey: Self.directCaptureReadyDefaultsKey
            ),
            onPermissionSetupStarted: { [weak self] permissionStep in
                self?.permissionSetupStarted(for: permissionStep)
            },
            onPermissionCompanionLayoutReady: { [weak self] in
                self?.permissionCompanionLayoutReady()
            },
            onExpandedRequested: { [weak self] in
                self?.showExpandedOnboarding(resetStep: false)
            },
            onOnboardingCompleted: { [weak self] in self?.onboardingCompleted() }
        )
        let window = ComputerUseOnboardingWindow(
            contentRect: NSRect(origin: .zero, size: Self.expandedWindowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.computerUse.onboarding")
        window.title = String(localized: "computerUse.onboarding.windowTitle", defaultValue: "Computer Use Setup")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // NSPanel hides on app deactivation by default; onboarding must stay
        // visible beside System Settings while cmux is inactive.
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.contentView = ComputerUseOnboardingHostingView(rootView: rootView)
        configureForExpandedOnboarding(
            window,
            frame: NSRect(origin: window.frame.origin, size: Self.expandedWindowSize)
        )
        window.center()
        return window
    }

    private func permissionSetupStarted(for permissionStep: ComputerUseOnboardingStep) {
        guard let window else { return }
        pendingPermissionStep = permissionStep
        permissionSettingsWillOpen()
        window.orderFrontRegardless()
    }

    func dismiss() {
        stopSystemSettingsObservation()
        completionDismissTask?.cancel()
        completionDismissTask = nil
        dismissPermissionCompanion()
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window
        else { return }
        stopSystemSettingsObservation()
        dismissPermissionCompanion()
        closingWindow.delegate = nil
        window = nil
    }

    private func stopSystemSettingsObservation() {
        systemSettingsActivationTask?.cancel()
        systemSettingsActivationTask = nil
        systemSettingsPlacementRetryTask?.cancel()
        systemSettingsPlacementRetryTask = nil
        systemSettingsTrackingTask?.cancel()
        systemSettingsTrackingTask = nil
        pendingPlacementRequestID = nil
        systemSettingsActivatedForPendingRequest = false
        pendingPermissionCompanionFrame = nil
        pendingPermissionStep = nil
    }

    private func observeSystemSettingsActivation() {
        systemSettingsActivationTask = Task { @MainActor [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didActivateApplicationNotification
            ) {
                guard !Task.isCancelled else { return }
                self?.systemSettingsDidActivate()
            }
        }
    }

    private func permissionSettingsWillOpen() {
        systemSettingsPlacementRetryTask?.cancel()
        systemSettingsPlacementRetryTask = nil
        systemSettingsTrackingTask?.cancel()
        systemSettingsTrackingTask = nil
        let requestID = UUID()
        pendingPlacementRequestID = requestID
        systemSettingsActivatedForPendingRequest = false
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == Self.systemSettingsBundleIdentifier
        {
            systemSettingsActivatedForPendingRequest = true
            beginSystemSettingsPlacementRetry(requestID: requestID)
        }
    }

    private func systemSettingsDidActivate() {
        guard let requestID = pendingPlacementRequestID else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == Self.systemSettingsBundleIdentifier
        else { return }
        systemSettingsActivatedForPendingRequest = true
        beginSystemSettingsPlacementRetry(requestID: requestID)
    }

    private func beginSystemSettingsPlacementRetry(requestID: UUID) {
        guard
            systemSettingsActivatedForPendingRequest,
            systemSettingsPlacementRetryTask == nil
        else {
            return
        }
        systemSettingsPlacementRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !Task.isCancelled,
                  pendingPlacementRequestID == requestID,
                  clock.now < deadline
            {
                if let frame = permissionCompanionFrameInSystemSettings(),
                   let window,
                   let pendingPermissionStep
                {
                    pendingPermissionCompanionFrame = frame
                    let startingFrame = Self.permissionCompanionStartingFrame(
                        centeredOver: window.frame
                    )
                    configureForPermissionCompanion(
                        window,
                        permissionStep: pendingPermissionStep,
                        frame: startingFrame
                    )
                    systemSettingsPlacementRetryTask = nil
                    // The borderless companion's onAppear is the deterministic
                    // layout handshake. Only that compact window moves; the
                    // expanded onboarding window has already been ordered out.
                    if presentationState?.permissionCompanionLayoutReady == true {
                        permissionCompanionLayoutReady()
                    }
                    return
                }
                do {
                    // CGWindowList has no window-created signal. Once the
                    // matching app activates, wait until its real window is
                    // available rather than performing a provisional jump.
                    try await clock.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            if pendingPlacementRequestID == requestID {
                pendingPlacementRequestID = nil
                systemSettingsActivatedForPendingRequest = false
                systemSettingsPlacementRetryTask = nil
            }
        }
    }

    private func permissionCompanionLayoutReady() {
        guard
            let requestID = pendingPlacementRequestID,
            let frame = pendingPermissionCompanionFrame,
            presentationState?.permissionCompanionLayoutReady == true,
            let companionWindow = permissionCompanionWindow
        else {
            return
        }
        companionWindow.contentView?.layoutSubtreeIfNeeded()
        companionWindow.displayIfNeeded()
        guard pendingPlacementRequestID == requestID else { return }
        pendingPlacementRequestID = nil
        pendingPermissionCompanionFrame = nil
        systemSettingsActivatedForPendingRequest = false
        positionPermissionCompanion(at: frame, animate: true) { [weak self, weak companionWindow] in
            guard
                let self,
                let companionWindow,
                self.permissionCompanionWindow === companionWindow
            else { return }
            self.beginSystemSettingsTracking()
        }
    }

    @discardableResult
    private func positionInsideSystemSettingsIfNeeded(animate: Bool) -> Bool {
        guard let frame = permissionCompanionFrameInSystemSettings() else {
            return false
        }
        positionPermissionCompanion(at: frame, animate: animate)
        return true
    }

    private func permissionCompanionFrameInSystemSettings() -> NSRect? {
        guard let systemSettingsFrame = systemSettingsWindowFrame() else {
            return nil
        }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let permissionDisplay = permissionWindowPlacement.visibleFrame(
            containing: systemSettingsFrame,
            candidates: visibleFrames
        ) else {
            return nil
        }

        return permissionWindowPlacement.frame(
            onboardingSize: Self.permissionCompanionWindowSize,
            beside: systemSettingsFrame,
            in: permissionDisplay
        )
    }

    private func positionPermissionCompanion(
        at frame: NSRect,
        animate: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard let permissionCompanionWindow else {
            completion?()
            return
        }
        guard permissionCompanionWindow.frame != frame else {
            completion?()
            return
        }
        permissionCompanionWindow.setAppKitOwnedFrame(
            frame,
            display: permissionCompanionWindow.isVisible,
            animate: animate && shouldAnimate(permissionCompanionWindow),
            duration: Self.permissionCompanionGlideDuration,
            completion: completion
        )
    }

    private func beginSystemSettingsTracking() {
        systemSettingsTrackingTask?.cancel()
        systemSettingsTrackingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            var consecutiveMissingWindowChecks = 0
            while !Task.isCancelled {
                // The initial move is the only animated transition. Repeated
                // `setFrame(..., animate: true)` calls while System Settings is
                // being dragged queue competing AppKit interpolations and make
                // the companion visibly lag or snap backward.
                if positionInsideSystemSettingsIfNeeded(animate: false) {
                    consecutiveMissingWindowChecks = 0
                } else {
                    consecutiveMissingWindowChecks += 1
                    if consecutiveMissingWindowChecks >= 3 {
                        showExpandedOnboarding()
                        return
                    }
                }
                do {
                    // Track at roughly 30fps. Each move is origin-only and
                    // nonanimated, so it follows System Settings continuously
                    // without queuing competing AppKit frame animations.
                    try await clock.sleep(for: .milliseconds(33))
                } catch {
                    return
                }
            }
        }
    }

    private func systemSettingsWindowFrame() -> CGRect? {
        let processIdentifiers = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.systemSettingsBundleIdentifier
            ).map(\.processIdentifier)
        )
        guard !processIdentifiers.isEmpty else { return nil }
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let primaryScreenMaxY = primaryScreenFrame()?.maxY ?? 0
        return windowInfo.compactMap { entry -> CGRect? in
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  processIdentifiers.contains(pid_t(ownerPID.int32Value)),
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return permissionWindowPlacement.appKitFrame(
                fromQuartz: quartzFrame,
                primaryScreenMaxY: primaryScreenMaxY
            )
        }.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }
    }

    private func primaryScreenFrame() -> CGRect? {
        let primaryDisplayID = CGMainDisplayID()
        return NSScreen.screens.first { screen in
            let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
            let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber
            return screenNumber?.uint32Value == primaryDisplayID
        }?.frame ?? NSScreen.screens.first?.frame
    }

    private func showExpandedOnboarding(
        resetStep: Bool = true,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard let window else { return }
        systemSettingsPlacementRetryTask?.cancel()
        systemSettingsPlacementRetryTask = nil
        systemSettingsTrackingTask?.cancel()
        systemSettingsTrackingTask = nil
        pendingPlacementRequestID = nil
        systemSettingsActivatedForPendingRequest = false
        pendingPermissionCompanionFrame = nil
        pendingPermissionStep = nil
        revealExpandedOnboarding(
            window,
            resetStep: resetStep,
            completed: false
        )
        completion?()
    }

    /// Replaces the compact companion with the centered main onboarding window.
    /// The companion closes immediately; there is deliberately no return glide.
    func revealExpandedOnboarding(
        _ window: ComputerUseOnboardingWindow,
        resetStep: Bool,
        completed: Bool
    ) {
        if completed {
            guard presentationState?.showCompletionInExpandedOnboarding() != false else {
                return
            }
        } else {
            presentationState?.requestExpandedPresentation(resetToOverview: resetStep)
        }
        dismissPermissionCompanion()
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? window.frame
        let expandedFrame = NSRect(
            x: visibleFrame.midX - Self.expandedWindowSize.width / 2,
            y: visibleFrame.midY - Self.expandedWindowSize.height / 2,
            width: Self.expandedWindowSize.width,
            height: Self.expandedWindowSize.height
        )
        configureForExpandedOnboarding(window, frame: expandedFrame)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func onboardingCompleted() {
        guard presentationState?.screenCaptureConsentPending != true else { return }
        completionDismissTask?.cancel()
        completionDismissTask = nil
        systemSettingsPlacementRetryTask?.cancel()
        systemSettingsPlacementRetryTask = nil
        systemSettingsTrackingTask?.cancel()
        systemSettingsTrackingTask = nil
        pendingPlacementRequestID = nil
        systemSettingsActivatedForPendingRequest = false
        pendingPermissionCompanionFrame = nil
        pendingPermissionStep = nil
        userDefaults.set(true, forKey: Self.directCaptureReadyDefaultsKey)
        runtimeService.onboardingWasCompleted()
        guard let window else { return }
        revealExpandedOnboarding(
            window,
            resetStep: false,
            completed: true
        )
        scheduleCompletionDismissal()
    }

    private func scheduleCompletionDismissal() {
        completionDismissTask?.cancel()
        completionDismissTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: Self.completionDismissDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.completionDismissTask = nil
            self.dismiss()
        }
    }

    /// Orders out the expanded onboarding window and presents an independent,
    /// borderless permission companion at its fixed compact frame.
    func configureForPermissionCompanion(
        _ mainWindow: ComputerUseOnboardingWindow,
        permissionStep: ComputerUseOnboardingStep = .accessibility,
        frame: NSRect,
        animate: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        prepareForPermissionCompanion(mainWindow)
        if presentationState?.permissionCompanionVisible != true {
            presentationState?.showPermissionCompanion()
        }
        dismissPermissionCompanion()
        let companionWindow = makePermissionCompanionWindow(
            permissionStep: permissionStep,
            frame,
            mainWindow: mainWindow
        )
        permissionCompanionWindow = companionWindow
        companionWindow.orderFrontRegardless()
        if animate && shouldAnimate(companionWindow) {
            companionWindow.setAppKitOwnedFrame(
                frame,
                display: true,
                animate: true,
                duration: Self.permissionCompanionGlideDuration,
                completion: completion
            )
        } else {
            companionWindow.displayIfNeeded()
            completion?()
        }
    }

    /// Hides the main window before the companion appears. Its frame and chrome
    /// remain untouched so revealing it later cannot expose a ghost titlebar.
    func prepareForPermissionCompanion(
        _ window: ComputerUseOnboardingWindow
    ) {
        window.orderOut(nil)
    }

    private func makePermissionCompanionWindow(
        permissionStep: ComputerUseOnboardingStep,
        _ frame: NSRect,
        mainWindow: ComputerUseOnboardingWindow
    ) -> ComputerUseOnboardingWindow {
        let rootView = ComputerUsePermissionCompanionView(
            permissionStep: permissionStep,
            presentationState: presentationState
                ?? ComputerUseOnboardingPresentationState(),
            applicationName: runtimeService.applicationName,
            helperAppURL: runtimeService.helperAppURL,
            onBack: { [weak self] in
                guard let self else { return }
                self.showExpandedOnboarding(resetStep: false)
                Task { @MainActor [weak self] in
                    _ = await self?.runtimeService.refreshHelperStatus()
                }
            },
            onDragEnded: { [weak self] operation in
                guard operation != [] else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let status = await self.runtimeService
                        .refreshHelperStatusAfterPermissionChange()
                    guard !Task.isCancelled else { return }
                    self.presentationState?.publishPermissionSnapshot(
                        statusIsKnown: self.runtimeService
                            .permissionStatusIsKnown,
                        accessibilityGranted: status.accessibility,
                        screenRecordingGranted: status.screenRecording
                    )
                }
            },
            onLayoutReady: { [weak self] in
                guard let self else { return }
                if self.presentationState?.markPermissionCompanionLayoutReady() == true {
                    self.permissionCompanionLayoutReady()
                }
            }
        )
        // Nonactivating: interacting with the companion (dragging the helper
        // tile, pressing Back) must not activate cmux, or the main terminal
        // window raises over the System Settings pane the user is working in.
        let companionWindow = ComputerUseOnboardingWindow(
            contentRect: NSRect(origin: .zero, size: Self.permissionCompanionWindowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        companionWindow.identifier = NSUserInterfaceItemIdentifier(
            "cmux.computerUse.onboarding.permissionCompanion"
        )
        companionWindow.isReleasedWhenClosed = false
        companionWindow.becomesKeyOnlyIfNeeded = true
        companionWindow.level = .floating
        companionWindow.collectionBehavior = [.canJoinAllSpaces]
        companionWindow.hidesOnDeactivate = false
        companionWindow.hasShadow = false
        companionWindow.isOpaque = false
        companionWindow.backgroundColor = .clear
        companionWindow.isMovable = false
        companionWindow.contentView = ComputerUseOnboardingHostingView(rootView: rootView)
        companionWindow.setAppKitOwnedFrame(frame, display: false)
        companionWindow.appearance = mainWindow.appearance
        return companionWindow
    }

    private func dismissPermissionCompanion() {
        permissionCompanionWindow?.orderOut(nil)
        permissionCompanionWindow?.close()
        permissionCompanionWindow = nil
    }

    nonisolated static func permissionCompanionStartingFrame(
        centeredOver mainFrame: NSRect
    ) -> NSRect {
        NSRect(
            x: mainFrame.midX - permissionCompanionWindowSize.width / 2,
            y: mainFrame.midY - permissionCompanionWindowSize.height / 2,
            width: permissionCompanionWindowSize.width,
            height: permissionCompanionWindowSize.height
        )
    }

    private func configureForExpandedOnboarding(
        _ window: ComputerUseOnboardingWindow,
        frame: NSRect,
        animate: Bool = false
    ) {
        window.styleMask = Self.expandedWindowStyleMask
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 0
        window.contentView?.layer?.masksToBounds = false
        configureStandardButtons(window, visible: true)
        window.setAppKitOwnedFrame(
            frame,
            display: window.isVisible,
            animate: animate
        )
    }

    private func configureStandardButtons(
        _ window: ComputerUseOnboardingWindow,
        visible: Bool
    ) {
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(buttonType)
            button?.isHidden = !visible
            button?.isEnabled = visible && buttonType == .closeButton
        }
    }

    private func shouldAnimate(_ window: NSWindow) -> Bool {
        Self.shouldAnimate(
            windowIsVisible: window.isVisible,
            reduceMotion:
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    nonisolated static func shouldAnimate(
        windowIsVisible: Bool,
        reduceMotion: Bool
    ) -> Bool {
        windowIsVisible && !reduceMotion
    }

}
