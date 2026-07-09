#if DEBUG
import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct SplitButtonLayoutDebugWindowControllerTests {
    /// Presenting the panel must build a window carrying the stable auxiliary
    /// identifier the close-shortcut routing keys on, and must route chrome
    /// decoration through the injected ``WindowDecorating`` seam exactly once.
    @Test func showBuildsPanelAndDecoratesThroughSeam() {
        let decorator = RecordingDecorator()
        let controller = SplitButtonLayoutDebugWindowController(decorator: decorator)

        controller.show()

        let window = controller.window
        #expect(window != nil)
        #expect(window?.identifier?.rawValue == "cmux.splitButtonLayoutDebug")
        #expect(decorator.decorated.count == 1)
        #expect(decorator.decorated.first === window)
    }

    /// A nil decorator must not crash presentation; the panel still builds.
    @Test func showWithoutDecoratorStillBuildsPanel() {
        let controller = SplitButtonLayoutDebugWindowController(decorator: nil)

        controller.show()

        #expect(controller.window?.identifier?.rawValue == "cmux.splitButtonLayoutDebug")
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
