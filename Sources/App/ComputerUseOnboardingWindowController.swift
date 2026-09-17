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
    private let externalWindowCompanionPresenter: ExternalWindowCompanionPresenter
    private var systemSettingsWindowTracker: ExternalApplicationWindowTracker?
    private var permissionCompanionRequested = false
    private var pendingPermissionStep: ComputerUseOnboardingStep?
    private var presentationState: ComputerUseOnboardingPresentationState?
    private var completionDismissTask: Task<Void, Never>?

    init(
        runtimeService: ComputerUseRuntimeService,
        userDefaults: UserDefaults = .standard,
        externalWindowCompanionPresenter: ExternalWindowCompanionPresenter? = nil
    ) {
        self.runtimeService = runtimeService
        self.userDefaults = userDefaults
        self.externalWindowCompanionPresenter = externalWindowCompanionPresenter
            ?? ExternalWindowCompanionPresenter()
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
        // `seen` is only a presentation marker; it does not prove helper TCC
        // grants remain valid. Missing or unknown grants must fail closed.
        _ = seen
        return featureEnabled
            && (
                !directCaptureReady
                    || !permissionStatusIsKnown
                    || !(accessibilityGranted && screenRecordingGranted)
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
        window.level = .normal
        window.collectionBehavior = [.managed]
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
        // The retained overview can start a different permission while a
        // companion is already visible. Replace that step's content and tracker.
        stopSystemSettingsObservation()
        dismissPermissionCompanion()
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
        systemSettingsWindowTracker?.stop()
        systemSettingsWindowTracker = nil
        permissionCompanionRequested = false
        pendingPermissionStep = nil
    }

    private func observeSystemSettingsWindow() {
        let tracker = ExternalApplicationWindowTracker(
            bundleIdentifier: Self.systemSettingsBundleIdentifier
        )
        systemSettingsWindowTracker = tracker
        tracker.start { [weak self] event in
            self?.handleSystemSettingsWindowEvent(event)
        }
    }

    private func permissionSettingsWillOpen() {
        permissionCompanionRequested = true
        if systemSettingsWindowTracker == nil {
            observeSystemSettingsWindow()
        } else {
            systemSettingsWindowTracker?.refreshFrontmostApplication()
        }
    }

    func handleSystemSettingsWindowEvent(
        _ event: ExternalApplicationWindowTracker.Event
    ) {
        switch event {
        case .hidden:
            // Keep both onboarding windows visible when another app activates.
            // The companion keeps its floating level until this flow ends.
            break
        case .offscreen:
            // Preserve the permission request and target identity across Spaces
            // and minimization. Recreate on the target's Space when it returns.
            if permissionCompanionWindow != nil {
                permissionCompanionRequested = true
                dismissPermissionCompanion()
            }
        case .unavailable:
            guard permissionCompanionRequested
                    || permissionCompanionWindow != nil
            else {
                return
            }
            // Window disappearance is not a request to activate cmux. The
            // overview is already visible at its original position.
            stopSystemSettingsObservation()
            dismissPermissionCompanion()
            presentationState?.requestExpandedPresentation(resetToOverview: false)
        case .visible(let snapshot):
            showPermissionCompanion(for: snapshot)
        }
    }

    private func showPermissionCompanion(
        for systemSettingsWindow: ExternalApplicationWindowTracker.Snapshot
    ) {
        guard permissionCompanionRequested
                || permissionCompanionWindow != nil,
              let destinationFrame = permissionCompanionFrame(
                beside: systemSettingsWindow.frame
              )
        else {
            return
        }

        if permissionCompanionWindow != nil {
            permissionCompanionRequested = false
            positionPermissionCompanion(
                at: destinationFrame,
                animate: false
            )
            return
        }

        guard let window, let pendingPermissionStep else { return }
        permissionCompanionRequested = false
        configureForPermissionCompanion(
            window,
            permissionStep: pendingPermissionStep,
            frame: destinationFrame
        )
    }

    private func permissionCompanionFrame(
        beside systemSettingsFrame: NSRect
    ) -> NSRect? {
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
            display: animate && permissionCompanionWindow.isVisible,
            animate: animate && shouldAnimate(permissionCompanionWindow),
            duration: Self.permissionCompanionGlideDuration,
            completion: completion
        )
    }

    private func showExpandedOnboarding(
        resetStep: Bool = true,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard let window else { return }
        stopSystemSettingsObservation()
        revealExpandedOnboarding(
            window,
            resetStep: resetStep,
            completed: false
        )
        completion?()
    }

    /// Closes the compact companion and brings the retained main onboarding
    /// window forward. There is deliberately no return glide.
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
        stopSystemSettingsObservation()
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

    /// Keeps the expanded onboarding window in place and presents an
    /// independent borderless permission companion at its fixed compact frame.
    func configureForPermissionCompanion(
        _ mainWindow: ComputerUseOnboardingWindow,
        permissionStep: ComputerUseOnboardingStep = .accessibility,
        frame: NSRect,
        animate: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        pendingPermissionStep = permissionStep
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
        externalWindowCompanionPresenter.present(companionWindow)
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
                _ = self?.presentationState?.markPermissionCompanionLayoutReady()
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
