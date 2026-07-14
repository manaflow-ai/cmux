import AppKit
import SwiftUI

/// Presents and reuses the nonmodal computer-use onboarding window.
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
        featureEnabled && !seen && !(accessibilityGranted && screenRecordingGranted)
    }

    func present() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let rootView = ComputerUseOnboardingView(
            permissionService: permissionService,
            onClose: { [weak self] in self?.window?.close() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "computerUse.onboarding.windowTitle", defaultValue: "Computer Use Setup")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
