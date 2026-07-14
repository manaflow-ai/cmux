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
        // Surface whenever a required permission is missing — NOT gated on `seen`.
        // A dev rebuild changes the app's code signature, so macOS drops the
        // prior TCC grant and permissions go missing again; gating on `seen`
        // meant onboarding never re-appeared to help the user re-grant. When both
        // permissions are already granted this is false, so a fully-set-up user
        // is never nagged. `seen` still suppresses the pure first-run intro only
        // when nothing is missing (handled by the caller's step selection).
        _ = seen
        return featureEnabled && !(accessibilityGranted && screenRecordingGranted)
    }

    func present() {
        window?.close()
        let window = makeWindow()
        self.window = window
        // A dev/background-launched app does not reliably steal focus, so a
        // normal-level window opens buried behind whatever is frontmost and the
        // user never sees the setup prompt. Float it above other apps and show
        // it on the active Space so it is always visible when permissions are
        // missing. Dropped back to normal level once it is key.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace]
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak window] in
            window?.level = .normal
        }
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
