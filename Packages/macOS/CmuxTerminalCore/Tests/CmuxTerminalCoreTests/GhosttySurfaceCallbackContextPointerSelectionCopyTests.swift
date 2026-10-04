import Foundation
import Testing
import CmuxTerminalCore
import GhosttyKit

private final class FakeSurfaceController: TerminalSurfaceControlling {
    let surfaceId = UUID()
    let owningTabId = UUID()
    var runtimeSurfacePointer: ghostty_surface_t?
}

private final class FakeSurfaceHost: TerminalSurfaceHosting {
    var hostedTabId: UUID?
    var attachedSurfaceController: (any TerminalSurfaceControlling)?
}

@Suite struct GhosttySurfaceCallbackContextPointerSelectionCopyTests {
    private static func makeContext() -> GhosttySurfaceCallbackContext {
        GhosttySurfaceCallbackContext(
            surfaceHost: FakeSurfaceHost(),
            surfaceController: FakeSurfaceController(),
            terminalLifecycleID: UUID()
        )
    }

    @Test func intentIsScopedToItsDispatch() {
        let context = Self.makeContext()

        #expect(!context.hasPointerSelectionCopyIntent)
        let sawIntent = context.withPointerSelectionCopyIntent {
            context.hasPointerSelectionCopyIntent
        }
        #expect(sawIntent)
        #expect(!context.hasPointerSelectionCopyIntent)
    }

    @Test func intentDoesNotLeakToOtherSurfaces() {
        let context = Self.makeContext()
        let otherContext = Self.makeContext()

        let otherSawIntent = context.withPointerSelectionCopyIntent {
            otherContext.hasPointerSelectionCopyIntent
        }
        #expect(!otherSawIntent)
    }

    @Test func nestedDispatchRestoresOuterIntent() {
        let context = Self.makeContext()
        let otherContext = Self.makeContext()

        let outerSawIntentAfterNested = context.withPointerSelectionCopyIntent {
            otherContext.withPointerSelectionCopyIntent {}
            return context.hasPointerSelectionCopyIntent
        }
        #expect(outerSawIntentAfterNested)
    }

    @Test func pasteIntentIsNotPointerSelectionCopyIntent() {
        let context = Self.makeContext()

        let sawIntent = context.withRuntimeClipboardPasteIntent {
            context.hasPointerSelectionCopyIntent
        }
        #expect(!sawIntent)
    }

    @Test func intentIsClearedWhenDispatchThrows() {
        struct DispatchFailure: Error {}
        let context = Self.makeContext()

        #expect(throws: DispatchFailure.self) {
            try context.withPointerSelectionCopyIntent {
                throw DispatchFailure()
            }
        }
        #expect(!context.hasPointerSelectionCopyIntent)
    }
}
