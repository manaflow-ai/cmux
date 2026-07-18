import AppKit
import SwiftUI

/// Presents a fresh nonmodal computer-use onboarding window for each run.
@MainActor
final class ComputerUseOnboardingWindowController {
    static let seenDefaultsKey = "cmux.computerUse.onboarding.seen"

    private var window: NSWindow?
    private let runtimeService: ComputerUseRuntimeService

    init(runtimeService: ComputerUseRuntimeService) {
        self.runtimeService = runtimeService
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

    func present() {
        window?.close()
        let window = makeWindow()
        self.window = window
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces]
        window.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func makeWindow() -> NSWindow {
        let rootView = ComputerUseOnboardingView(
            runtimeService: runtimeService,
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
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.contentMaxSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
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
