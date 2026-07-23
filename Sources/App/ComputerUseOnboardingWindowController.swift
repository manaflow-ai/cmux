import AppKit
import Combine
import SwiftUI

@MainActor
final class ComputerUseOnboardingPresentationState: ObservableObject {
    @Published private(set) var returnToOverviewGeneration = 0

    func requestReturnToOverview() {
        returnToOverviewGeneration &+= 1
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
    private static let expandedWindowSize = NSSize(width: 600, height: 440)
    private static let permissionCompanionWindowSize = NSSize(width: 532, height: 110)
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
    private var presentationState: ComputerUseOnboardingPresentationState?

    init(runtimeService: ComputerUseRuntimeService) {
        self.runtimeService = runtimeService
        super.init()
    }

    static func shouldPresentAutomatically(
        seen _: Bool,
        featureEnabled: Bool,
        permissionStatusIsKnown: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool
    ) -> Bool {
        featureEnabled
            && (
                !permissionStatusIsKnown
                    || !(accessibilityGranted && screenRecordingGranted)
            )
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func present(startingAt startingPoint: StartingPoint = .overview) {
        stopSystemSettingsObservation()
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
            onSystemSettingsOpened: { [weak self] in
                self?.showPermissionCompanion()
            },
            onExpandedRequested: { [weak self] in self?.showExpandedOnboarding() },
            onCompleted: { [weak self] in self?.dismiss() }
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

    private func showPermissionCompanion() {
        guard let window else { return }
        permissionSettingsWillOpen()
        window.orderFrontRegardless()
    }

    func dismiss() {
        stopSystemSettingsObservation()
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
        pendingPlacementRequestID = nil
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
        let requestID = UUID()
        pendingPlacementRequestID = requestID
        if positionInsideSystemSettingsIfNeeded(animate: true) {
            pendingPlacementRequestID = nil
            beginSystemSettingsTracking()
            return
        }
        guard let window else { return }
        let provisionalFrame = NSRect(
            origin: window.frame.origin,
            size: Self.permissionCompanionWindowSize
        )
        configureForPermissionCompanion(
            window,
            frame: provisionalFrame,
            animate: shouldAnimate(window)
        )
        beginSystemSettingsPlacementRetry(requestID: requestID)
    }

    private func systemSettingsDidActivate() {
        guard let requestID = pendingPlacementRequestID else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == Self.systemSettingsBundleIdentifier
        else { return }
        beginSystemSettingsPlacementRetry(requestID: requestID)
    }

    private func beginSystemSettingsPlacementRetry(requestID: UUID) {
        guard systemSettingsPlacementRetryTask == nil else { return }
        systemSettingsPlacementRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if pendingPlacementRequestID == requestID {
                    pendingPlacementRequestID = nil
                    systemSettingsPlacementRetryTask = nil
                }
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while !Task.isCancelled,
                  pendingPlacementRequestID == requestID,
                  clock.now < deadline
            {
                if positionInsideSystemSettingsIfNeeded(animate: true) {
                    beginSystemSettingsTracking()
                    return
                }
                do {
                    // CGWindowList has no window-created signal, so retry briefly after activation.
                    try await clock.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    @discardableResult
    private func positionInsideSystemSettingsIfNeeded(animate: Bool) -> Bool {
        guard let window, let systemSettingsFrame = systemSettingsWindowFrame() else { return false }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let permissionDisplay = permissionWindowPlacement.visibleFrame(
            containing: systemSettingsFrame,
            candidates: visibleFrames
        ) else { return false }

        let frame = permissionWindowPlacement.frame(
            onboardingSize: Self.permissionCompanionWindowSize,
            beside: systemSettingsFrame,
            in: permissionDisplay
        )
        guard window.frame != frame else { return true }
        configureForPermissionCompanion(
            window,
            frame: frame,
            animate: animate && shouldAnimate(window)
        )
        return true
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
                if positionInsideSystemSettingsIfNeeded(animate: false) {
                    consecutiveMissingWindowChecks = 0
                } else {
                    consecutiveMissingWindowChecks += 1
                    if consecutiveMissingWindowChecks >= 3 {
                        presentationState?.requestReturnToOverview()
                        showExpandedOnboarding()
                        return
                    }
                }
                do {
                    try await clock.sleep(for: .milliseconds(150))
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

    private func showExpandedOnboarding() {
        guard let window else { return }
        systemSettingsPlacementRetryTask?.cancel()
        systemSettingsPlacementRetryTask = nil
        systemSettingsTrackingTask?.cancel()
        systemSettingsTrackingTask = nil
        pendingPlacementRequestID = nil
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? window.frame
        let expandedFrame = NSRect(
            x: visibleFrame.midX - Self.expandedWindowSize.width / 2,
            y: visibleFrame.midY - Self.expandedWindowSize.height / 2,
            width: Self.expandedWindowSize.width,
            height: Self.expandedWindowSize.height
        )
        configureForExpandedOnboarding(
            window,
            frame: expandedFrame,
            animate: shouldAnimate(window)
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Applies the compact permission presentation without changing its behavior.
    ///
    /// Kept as one shared path for provisional and System Settings-relative
    /// placement so the real transition can be exercised by the app test target.
    func configureForPermissionCompanion(
        _ window: ComputerUseOnboardingWindow,
        frame: NSRect,
        animate: Bool = false
    ) {
        window.styleMask = [.borderless]
        window.hasShadow = true
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
        window.minSize = frame.size
        window.maxSize = frame.size
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(buttonType)
            button?.isHidden = !showsStandardButtons
            button?.isEnabled = showsStandardButtons && buttonType == .closeButton
        }
    }

    private func shouldAnimate(_ window: NSWindow) -> Bool {
        window.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

}
