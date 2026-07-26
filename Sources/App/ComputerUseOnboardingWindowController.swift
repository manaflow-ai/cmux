import AppKit
import Combine
import SwiftUI

@MainActor
final class ComputerUseOnboardingPresentationState: ObservableObject {
    @Published private(set) var returnToOverviewGeneration = 0
    @Published private(set) var permissionCompanionVisible = false
    @Published private(set) var permissionCompanionLayoutReady = false

    func showPermissionCompanion() {
        guard !permissionCompanionVisible else { return }
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

    func requestExpandedPresentation(resetToOverview: Bool = true) {
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
    static let completionDismissDelay: Duration = .seconds(2.4)
    private static let expandedWindowSize = NSSize(width: 600, height: 440)
    private static let permissionCompanionWindowSize = NSSize(width: 472, height: 112)
    private static let expandedWindowStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .fullSizeContentView,
    ]
    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    private var window: ComputerUseOnboardingWindow?
    private let runtimeService: ComputerUseRuntimeService
    private let permissionWindowPlacement = ComputerUseOnboardingWindowPlacement()
    private var systemSettingsActivationTask: Task<Void, Never>?
    private var systemSettingsPlacementRetryTask: Task<Void, Never>?
    private var systemSettingsTrackingTask: Task<Void, Never>?
    private var pendingPlacementRequestID: UUID?
    private var systemSettingsActivatedForPendingRequest = false
    private var pendingPermissionCompanionFrame: NSRect?
    private var presentationState: ComputerUseOnboardingPresentationState?
    private var expandedPresentationTask: Task<Void, Never>?
    private var completionDismissTask: Task<Void, Never>?

    init(runtimeService: ComputerUseRuntimeService) {
        self.runtimeService = runtimeService
        super.init()
    }

    static func shouldPresentAutomatically(
        seen: Bool,
        featureEnabled: Bool,
        permissionStatusIsKnown: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool
    ) -> Bool {
        !seen
            && featureEnabled
            && (
                !permissionStatusIsKnown
                    || !(accessibilityGranted && screenRecordingGranted)
            )
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func present(startingAt startingPoint: StartingPoint = .overview) {
        stopSystemSettingsObservation()
        completionDismissTask?.cancel()
        completionDismissTask = nil
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
            onPermissionSetupStarted: { [weak self] in
                self?.permissionSetupStarted()
            },
            onPermissionCompanionLayoutReady: { [weak self] in
                self?.permissionCompanionLayoutReady()
            },
            onExpandedRequested: { [weak self] in self?.showExpandedOnboarding() },
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
        window.isMovableByWindowBackground = false
        window.contentView = ComputerUseOnboardingHostingView(rootView: rootView)
        configureForExpandedOnboarding(
            window,
            frame: NSRect(origin: window.frame.origin, size: Self.expandedWindowSize)
        )
        window.center()
        return window
    }

    private func permissionSetupStarted() {
        guard let window else { return }
        permissionSettingsWillOpen()
        window.orderFrontRegardless()
    }

    func dismiss() {
        stopSystemSettingsObservation()
        completionDismissTask?.cancel()
        completionDismissTask = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window
        else { return }
        stopSystemSettingsObservation()
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
        expandedPresentationTask?.cancel()
        expandedPresentationTask = nil
        pendingPlacementRequestID = nil
        systemSettingsActivatedForPendingRequest = false
        pendingPermissionCompanionFrame = nil
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
                if let frame = permissionCompanionFrameInSystemSettings()
                {
                    pendingPermissionCompanionFrame = frame
                    presentationState?.showPermissionCompanion()
                    systemSettingsPlacementRetryTask = nil
                    // The compact view's onAppear is the deterministic layout
                    // handshake. It starts the frame interpolation only after
                    // SwiftUI has replaced the 600×440 content, preventing the
                    // expanded permission cards from being squeezed into the
                    // 472×112 destination during the glide.
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
            let window
        else {
            return
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard pendingPlacementRequestID == requestID else { return }
        positionPermissionCompanion(at: frame, animate: true)
        pendingPlacementRequestID = nil
        pendingPermissionCompanionFrame = nil
        systemSettingsActivatedForPendingRequest = false
        beginSystemSettingsTracking()
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
        animate: Bool
    ) {
        guard let window, window.frame != frame else { return }
        configureForPermissionCompanion(
            window,
            frame: frame,
            animate: animate && shouldAnimate(window)
        )
    }

    private func beginSystemSettingsTracking() {
        systemSettingsTrackingTask?.cancel()
        systemSettingsTrackingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            // Let AppKit finish the initial native frame interpolation before
            // switching to cheap steady-state placement checks.
            do {
                try await clock.sleep(for: .milliseconds(400))
            } catch {
                return
            }
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
        expandedPresentationTask?.cancel()
        expandedPresentationTask = nil
        systemSettingsPlacementRetryTask?.cancel()
        systemSettingsPlacementRetryTask = nil
        systemSettingsTrackingTask?.cancel()
        systemSettingsTrackingTask = nil
        pendingPlacementRequestID = nil
        systemSettingsActivatedForPendingRequest = false
        pendingPermissionCompanionFrame = nil
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? window.frame
        let expandedFrame = NSRect(
            x: visibleFrame.midX - Self.expandedWindowSize.width / 2,
            y: visibleFrame.midY - Self.expandedWindowSize.height / 2,
            width: Self.expandedWindowSize.width,
            height: Self.expandedWindowSize.height
        )
        let animate = shouldAnimate(window)
            && presentationState?.permissionCompanionVisible == true
        if animate {
            // Keep the already-laid-out compact card during the frame glide.
            // Swap in the expanded hierarchy only after the destination frame
            // is stable, the inverse of the compact-layout handshake above.
            window.setAppKitOwnedFrame(expandedFrame, display: true, animate: true)
            expandedPresentationTask = Task { @MainActor [weak self, weak window] in
                do {
                    try await ContinuousClock().sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                guard let self, let window, self.window === window else { return }
                self.finishExpandedPresentation(
                    window: window,
                    frame: expandedFrame,
                    resetStep: resetStep
                )
                self.expandedPresentationTask = nil
                completion?()
            }
        } else {
            finishExpandedPresentation(
                window: window,
                frame: expandedFrame,
                resetStep: resetStep
            )
            completion?()
        }
    }

    private func finishExpandedPresentation(
        window: ComputerUseOnboardingWindow,
        frame: NSRect,
        resetStep: Bool
    ) {
        configureForExpandedOnboarding(window, frame: frame, animate: false)
        presentationState?.requestExpandedPresentation(resetToOverview: resetStep)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func onboardingCompleted() {
        completionDismissTask?.cancel()
        completionDismissTask = nil
        showExpandedOnboarding(resetStep: false) { [weak self] in
            guard let self else { return }
            self.completionDismissTask = Task { @MainActor [weak self] in
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
    }

    /// Applies the compact permission presentation while preserving the
    /// expanded window's chrome and layout model.
    ///
    /// Changing style masks during a resize rebuilds AppKit's frame/content
    /// relationship mid-animation. Keeping one style mask lets the move and
    /// resize remain a single smooth transition.
    func configureForPermissionCompanion(
        _ window: ComputerUseOnboardingWindow,
        frame: NSRect,
        animate: Bool = false
    ) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 14
        window.contentView?.layer?.masksToBounds = true
        configure(
            window,
            frame: frame,
            showsStandardButtons: false,
            animate: animate
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
        window.hasShadow = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 0
        window.contentView?.layer?.masksToBounds = false
        configure(
            window,
            frame: frame,
            showsStandardButtons: true,
            animate: animate
        )
    }

    private func configure(
        _ window: ComputerUseOnboardingWindow,
        frame: NSRect,
        showsStandardButtons: Bool,
        animate: Bool = false
    ) {
        window.setAppKitOwnedFrame(
            frame,
            display: window.isVisible,
            animate: animate
        )
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(buttonType)
            button?.isHidden = !showsStandardButtons
            button?.isEnabled = showsStandardButtons && buttonType == .closeButton
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
