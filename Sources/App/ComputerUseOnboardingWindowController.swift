import AppKit
import SwiftUI

/// Presents a fresh nonmodal computer-use onboarding window for each run.
@MainActor
final class ComputerUseOnboardingWindowController {
    static let seenDefaultsKey = "cmux.computerUse.onboarding.seen"

    private var window: NSWindow?
    private let permissionService: ComputerUsePermissionService

    init() {
        self.permissionService = ComputerUsePermissionService()
    }

    init(permissionService: ComputerUsePermissionService) {
        self.permissionService = permissionService
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

    func present(startsAtPermissionStep: Bool = false) {
        window?.close()
        let window = makeWindow(startsAtPermissionStep: startsAtPermissionStep)
        self.window = window
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces]
        window.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func makeWindow(startsAtPermissionStep: Bool = false) -> NSWindow {
        let rootView = ComputerUseOnboardingView(
            permissionService: permissionService,
            startsAtPermissionStep: startsAtPermissionStep,
            onSystemSettingsOpened: { [weak self] in
                self?.positionForPermissionSetup()
            },
            onClose: { [weak self] in self?.window?.close() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "computerUse.onboarding.windowTitle", defaultValue: "Computer Use Setup")
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.contentMaxSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        return window
    }

    private func positionForPermissionSetup() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.minX + 24,
            y: visibleFrame.maxY - window.frame.height - 24
        )
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }
}
