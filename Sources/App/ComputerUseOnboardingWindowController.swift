import AppKit
import SwiftUI

/// Presents a fresh nonmodal computer-use onboarding window for each run.
@MainActor
final class ComputerUseOnboardingWindowController {
    static let seenDefaultsKey = "cmux.computerUse.onboarding.seen"

    private var window: NSWindow?
    private let permissionService: ComputerUsePermissionService
    private let agentSessionRequiresRestart: @MainActor () -> Bool

    init() {
        self.permissionService = ComputerUsePermissionService()
        self.agentSessionRequiresRestart = { false }
    }

    init(
        permissionService: ComputerUsePermissionService,
        agentSessionRequiresRestart: @escaping @MainActor () -> Bool = { false }
    ) {
        self.permissionService = permissionService
        self.agentSessionRequiresRestart = agentSessionRequiresRestart
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
        window?.close()
        let window = makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func makeWindow() -> NSWindow {
        let rootView = ComputerUseOnboardingView(
            permissionService: permissionService,
            agentSessionRequiresRestart: agentSessionRequiresRestart,
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
