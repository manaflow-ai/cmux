import AppKit
import SwiftUI

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
    private static let expandedWindowSize = NSSize(width: 596, height: 435)
    private static let permissionCompanionWindowSize = NSSize(width: 680, height: 250)
    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    private var window: ComputerUseOnboardingWindow?
    private let runtimeService: ComputerUseRuntimeService
    private let permissionWindowPlacement = ComputerUseOnboardingWindowPlacement()
    private var systemSettingsActivationTask: Task<Void, Never>?
    private var systemSettingsPlacementRetryTask: Task<Void, Never>?
    private var pendingPlacementRequestID: UUID?

    init(runtimeService: ComputerUseRuntimeService) {
        self.runtimeService = runtimeService
        super.init()
    }

    static func shouldPresentAutomatically(
        seen: Bool,
        featureEnabled: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool
    ) -> Bool {
        featureEnabled
            && !seen
            && !(accessibilityGranted && screenRecordingGranted)
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
        let rootView = ComputerUseOnboardingView(
            runtimeService: runtimeService,
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
        configure(
            window,
            windowSize: Self.expandedWindowSize,
            showsStandardButtons: true
        )
        window.center()
        return window
    }

    private func showPermissionCompanion() {
        guard let window else { return }
        configure(
            window,
            windowSize: Self.permissionCompanionWindowSize,
            showsStandardButtons: false
        )
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
        pendingPlacementRequestID = UUID()
        // This is provisional; activation retries against the post-request window frame.
        _ = positionBesideSystemSettingsIfNeeded()
    }

    private func systemSettingsDidActivate() {
        guard let requestID = pendingPlacementRequestID else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == Self.systemSettingsBundleIdentifier
        else { return }
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
                  clock.now < deadline,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == Self.systemSettingsBundleIdentifier
            {
                if positionBesideSystemSettingsIfNeeded() {
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
    private func positionBesideSystemSettingsIfNeeded() -> Bool {
        guard let window, let systemSettingsFrame = systemSettingsWindowFrame() else { return false }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let permissionDisplay = permissionWindowPlacement.visibleFrame(
            containing: systemSettingsFrame,
            candidates: visibleFrames
        ) else { return false }

        let frame = permissionWindowPlacement.frame(
            onboardingSize: window.frame.size,
            beside: systemSettingsFrame,
            in: permissionDisplay
        )
        window.setFrame(frame, display: true, animate: false)
        return true
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
        configure(
            window,
            windowSize: Self.expandedWindowSize,
            showsStandardButtons: true
        )
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func configure(
        _ window: ComputerUseOnboardingWindow,
        windowSize: NSSize,
        showsStandardButtons: Bool
    ) {
        window.minSize = windowSize
        window.maxSize = windowSize
        window.setAppKitOwnedFrame(
            NSRect(origin: window.frame.origin, size: windowSize),
            display: window.isVisible
        )
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(buttonType)
            button?.isHidden = !showsStandardButtons
            button?.isEnabled = showsStandardButtons && buttonType == .closeButton
        }
    }

}
