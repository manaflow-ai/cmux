import AppKit
import SwiftUI

/// Presents a fresh nonmodal computer-use onboarding window for each run.
@MainActor
final class ComputerUseOnboardingWindowController {
    enum StartingPoint: Sendable, Equatable {
        case overview
        case accessibility
        case screenRecording

        var step: Int {
            switch self {
            case .overview: 0
            case .accessibility: 1
            case .screenRecording: 2
            }
        }

    }

    static let seenDefaultsKey = "cmux.computerUse.onboarding.seen"

    private static let expandedContentSize = NSSize(width: 900, height: 665)
    private static let permissionCompanionContentSize = NSSize(width: 680, height: 250)
    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    private var window: NSWindow?
    private let runtimeService: ComputerUseRuntimeService
    private var systemSettingsActivationTask: Task<Void, Never>?
    private var isShowingPermissionCompanion = false

    init(runtimeService: ComputerUseRuntimeService) {
        self.runtimeService = runtimeService
        observeSystemSettingsActivation()
    }

    deinit {
        systemSettingsActivationTask?.cancel()
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
        window?.close()
        let window = makeWindow(startingAt: startingPoint)
        self.window = window
        isShowingPermissionCompanion = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces]
        window.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func makeWindow(startingAt startingPoint: StartingPoint = .overview) -> NSWindow {
        let rootView = ComputerUseOnboardingView(
            runtimeService: runtimeService,
            initialStep: startingPoint.step,
            onSystemSettingsOpened: { [weak self] in
                self?.showPermissionCompanion()
            },
            onExpandedRequested: { [weak self] in self?.showExpandedOnboarding() },
            onClose: { [weak self] in self?.window?.close() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "computerUse.onboarding.windowTitle", defaultValue: "Computer Use Setup")
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        configure(
            window,
            contentSize: Self.expandedContentSize,
            showsStandardButtons: true
        )
        window.center()
        return window
    }

    static func permissionCompanionOrigin(
        systemSettingsFrame: NSRect,
        companionSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let screenInset: CGFloat = 12
        let settingsBottomInset: CGFloat = 18
        let minimumX = visibleFrame.minX + screenInset
        let maximumX = max(minimumX, visibleFrame.maxX - companionSize.width - screenInset)
        let minimumY = visibleFrame.minY + screenInset
        let maximumY = max(minimumY, visibleFrame.maxY - companionSize.height - screenInset)
        let desiredX = systemSettingsFrame.midX - companionSize.width / 2
        let desiredY = systemSettingsFrame.minY + settingsBottomInset
        return NSPoint(
            x: min(max(desiredX, minimumX), maximumX),
            y: min(max(desiredY, minimumY), maximumY)
        )
    }

    private func showPermissionCompanion() {
        guard let window else { return }
        isShowingPermissionCompanion = true
        configure(
            window,
            contentSize: Self.permissionCompanionContentSize,
            showsStandardButtons: false
        )
        positionPermissionCompanion(
            window,
            systemSettingsFrame: frontmostSystemSettingsWindowFrame()
        )
        window.orderFrontRegardless()
    }

    private func showExpandedOnboarding() {
        guard let window else { return }
        isShowingPermissionCompanion = false
        configure(
            window,
            contentSize: Self.expandedContentSize,
            showsStandardButtons: true
        )
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func configure(
        _ window: NSWindow,
        contentSize: NSSize,
        showsStandardButtons: Bool
    ) {
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.setContentSize(contentSize)
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            window.standardWindowButton(buttonType)?.isHidden = !showsStandardButtons
        }
    }

    private func positionPermissionCompanion(
        _ window: NSWindow,
        systemSettingsFrame: NSRect?
    ) {
        let screen = systemSettingsFrame.flatMap(screen(containing:))
            ?? window.screen
            ?? NSScreen.main
        guard let screen else { return }
        let referenceFrame = systemSettingsFrame ?? screen.visibleFrame
        window.setFrameOrigin(Self.permissionCompanionOrigin(
            systemSettingsFrame: referenceFrame,
            companionSize: window.frame.size,
            visibleFrame: screen.visibleFrame
        ))
    }

    private func observeSystemSettingsActivation() {
        systemSettingsActivationTask?.cancel()
        systemSettingsActivationTask = Task { @MainActor [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didActivateApplicationNotification
            )
            for await notification in notifications {
                guard !Task.isCancelled, let self, isShowingPermissionCompanion else { continue }
                guard
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                    application.bundleIdentifier == Self.systemSettingsBundleIdentifier,
                    let window
                else {
                    continue
                }
                positionPermissionCompanion(
                    window,
                    systemSettingsFrame: frontmostSystemSettingsWindowFrame()
                )
                window.orderFrontRegardless()
            }
        }
    }

    private func frontmostSystemSettingsWindowFrame() -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return windows.compactMap { info -> NSRect? in
            guard
                (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
                    == Self.systemSettingsBundleIdentifier,
                let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
                let x = bounds["X"]?.doubleValue,
                let y = bounds["Y"]?.doubleValue,
                let width = bounds["Width"]?.doubleValue,
                let height = bounds["Height"]?.doubleValue,
                width > 300,
                height > 300
            else {
                return nil
            }
            let quartzFrame = CGRect(x: x, y: y, width: width, height: height)
            return appKitFrame(forQuartzFrame: quartzFrame)
        }
        .max { lhs, rhs in lhs.width * lhs.height < rhs.width * rhs.height }
    }

    private func appKitFrame(forQuartzFrame quartzFrame: CGRect) -> NSRect? {
        let quartzCenter = CGPoint(x: quartzFrame.midX, y: quartzFrame.midY)
        for screen in NSScreen.screens {
            guard
                let screenNumber = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                continue
            }
            let quartzScreenFrame = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard quartzScreenFrame.contains(quartzCenter) || quartzScreenFrame.intersects(quartzFrame) else {
                continue
            }
            return NSRect(
                x: screen.frame.minX + quartzFrame.minX - quartzScreenFrame.minX,
                y: screen.frame.maxY - (quartzFrame.maxY - quartzScreenFrame.minY),
                width: quartzFrame.width,
                height: quartzFrame.height
            )
        }
        return nil
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.screens.max { lhs, rhs in
                let lhsIntersection = lhs.frame.intersection(frame)
                let rhsIntersection = rhs.frame.intersection(frame)
                let lhsArea = lhsIntersection.isNull || lhsIntersection.isEmpty
                    ? 0
                    : lhsIntersection.width * lhsIntersection.height
                let rhsArea = rhsIntersection.isNull || rhsIntersection.isEmpty
                    ? 0
                    : rhsIntersection.width * rhsIntersection.height
                return lhsArea < rhsArea
            }
    }
}
