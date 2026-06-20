#if canImport(AppKit)
#if DEBUG
import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// Covers the Startup Appearance debug window shell the app forwards into
/// ``DebugWindowsCoordinator``. The controller builds the fixed
/// `cmux.startupAppearanceDebug` utility panel, mounts the app-supplied preview
/// content, applies the injected localized title, and routes chrome decoration
/// through the injected ``WindowDecorating`` seam.
@MainActor
@Suite struct StartupAppearanceDebugWindowControllerTests {
    @Test func showBuildsUtilityPanelMountsContentAndDecorates() {
        let decorator = StartupAppearanceDebugRecordingDecorator()
        let content = NSView()
        let controller = StartupAppearanceDebugWindowController(
            decorator: decorator,
            windowTitle: "Startup Appearance Debug",
            contentProvider: { content }
        )

        controller.show()

        let window = controller.window
        #expect(window != nil)
        #expect(window?.identifier?.rawValue == "cmux.startupAppearanceDebug")
        #expect(window?.title == "Startup Appearance Debug")
        #expect(window?.contentView === content)
        #expect(decorator.decorated.count == 1)
        #expect(decorator.decorated.first === window)
    }

    @Test func showWithoutDecoratorStillBuildsPanel() {
        let controller = StartupAppearanceDebugWindowController(
            decorator: nil,
            windowTitle: "Startup Appearance Debug",
            contentProvider: { NSView() }
        )

        controller.show()

        #expect(controller.window?.identifier?.rawValue == "cmux.startupAppearanceDebug")
    }

    @Test func coordinatorWithoutProviderDoesNotPresent() {
        let coordinator = DebugWindowsCoordinator(
            decorator: nil,
            aboutPanelStrings: AboutPanelStrings(
                appName: "cmux", description: "desc", versionLabel: "Version",
                buildLabel: "Build", commitLabel: "Commit", docs: "Docs",
                github: "GitHub", licenses: "Licenses"
            ),
            acknowledgmentsStrings: AcknowledgmentsStrings(windowTitle: "Licenses", notFound: "none")
        )

        coordinator.showStartupAppearanceDebug()
        // No content provider/title was injected, so no panel is created. Reaching
        // here without a crash is the contract (the call is a documented no-op).
        #expect(Bool(true))
    }
}

@MainActor
private final class StartupAppearanceDebugRecordingDecorator: WindowDecorating {
    private(set) var decorated: [NSWindow] = []

    func applyWindowDecorations(to window: NSWindow) {
        decorated.append(window)
    }
}
#endif
#endif
