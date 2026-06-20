#if DEBUG
import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// Covers the two injected-content debug window shells (Menu Bar Extra Debug and
/// Background Debug) the app forwards into ``DebugWindowsCoordinator``. Each builds
/// its panel with a stable auxiliary identifier, mounts the app-supplied content
/// view, and routes chrome decoration through the injected ``WindowDecorating`` seam.
@MainActor
@Suite struct InjectedContentDebugWindowControllerTests {
    @Test func menuBarExtraShowBuildsPanelMountsContentAndDecorates() {
        let decorator = RecordingDecorator()
        let content = NSView()
        let controller = MenuBarExtraDebugWindowController(
            decorator: decorator,
            contentProvider: { content }
        )

        controller.show()

        let window = controller.window
        #expect(window != nil)
        #expect(window?.identifier?.rawValue == "cmux.menubarDebug")
        #expect(window?.contentView === content)
        #expect(decorator.decorated.count == 1)
        #expect(decorator.decorated.first === window)
    }

    @Test func menuBarExtraShowWithoutDecoratorStillBuildsPanel() {
        let controller = MenuBarExtraDebugWindowController(
            decorator: nil,
            contentProvider: { NSView() }
        )

        controller.show()

        #expect(controller.window?.identifier?.rawValue == "cmux.menubarDebug")
    }

    @Test func backgroundShowBuildsPanelMountsContentAndDecorates() {
        let decorator = RecordingDecorator()
        let content = NSView()
        let controller = BackgroundDebugWindowController(
            decorator: decorator,
            contentProvider: { content }
        )

        controller.show()

        let window = controller.window
        #expect(window != nil)
        #expect(window?.identifier?.rawValue == "cmux.backgroundDebug")
        #expect(window?.contentView === content)
        #expect(decorator.decorated.count == 1)
        #expect(decorator.decorated.first === window)
    }

    @Test func backgroundShowWithoutDecoratorStillBuildsPanel() {
        let controller = BackgroundDebugWindowController(
            decorator: nil,
            contentProvider: { NSView() }
        )

        controller.show()

        #expect(controller.window?.identifier?.rawValue == "cmux.backgroundDebug")
    }
}

@MainActor
private final class RecordingDecorator: WindowDecorating {
    private(set) var decorated: [NSWindow] = []

    func applyWindowDecorations(to window: NSWindow) {
        decorated.append(window)
    }
}
#endif
