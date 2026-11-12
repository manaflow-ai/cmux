import Foundation
import Testing
import CmuxTerminalCore
import GhosttyKit

private final class FakeSurfaceController: TerminalSurfaceControlling {
    let surfaceId = UUID()
    let owningTabId = UUID()
    var runtimeSurfacePointer: ghostty_surface_t?
    var requiresClipboardReadGesture = false
}

private final class FakeSurfaceHost: TerminalSurfaceHosting {
    var hostedTabId: UUID?
    var attachedSurfaceController: (any TerminalSurfaceControlling)?
}

@Suite struct RuntimeClipboardReadContentTests {
    @Test @MainActor
    func terminalInitiatedReadGetsPlainTextOnly() throws {
        let context = try makeBoundContext()

        // An OSC 52 read reaches the callback with no native paste gesture
        // on the call stack.
        let didRegister = context.registerRuntimeClipboardRequest(
            id: 41,
            onInvalidation: { _, _, _, _ in }
        )
        #expect(didRegister)
        #expect(context.commitRuntimeClipboardRequest(41))
        let admission = try #require(
            context.markRuntimeClipboardRequestAdmitted(41)
        )

        #expect(RuntimeClipboardReadContent(admission: admission) == .plainText)
    }

    @Test @MainActor
    func nativePasteGetsTheWholePasteboard() throws {
        let context = try makeBoundContext()

        // Cmd+V, the Paste menu item and a middle click all dispatch inside
        // the paste intent.
        let didRegister = context.withRuntimeClipboardPasteIntent {
            context.registerRuntimeClipboardRequest(
                id: 43,
                onInvalidation: { _, _, _, _ in }
            )
        }
        #expect(didRegister)
        #expect(context.commitRuntimeClipboardRequest(43))
        let admission = try #require(
            context.markRuntimeClipboardRequestAdmitted(43)
        )

        #expect(RuntimeClipboardReadContent(admission: admission) == .pasteboard)
    }

    @Test @MainActor
    func manualMirrorReadsRequireNativePasteIntent() {
        let controller = FakeSurfaceController()
        controller.requiresClipboardReadGesture = true
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: FakeSurfaceHost(),
            surfaceController: controller,
            terminalLifecycleID: UUID()
        )

        #expect(!context.hasRuntimeClipboardPasteIntent)
        #expect(!context.allowsRuntimeClipboardRead)
        #expect(context.withRuntimeClipboardPasteIntent {
            context.hasRuntimeClipboardPasteIntent
        })
        #expect(context.withRuntimeClipboardPasteIntent {
            context.allowsRuntimeClipboardRead
        })
        #expect(!context.hasRuntimeClipboardPasteIntent)
    }

    @MainActor
    private func makeBoundContext() throws -> GhosttySurfaceCallbackContext {
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: FakeSurfaceHost(),
            surfaceController: FakeSurfaceController(),
            terminalLifecycleID: UUID()
        )
        let surface = try #require(ghostty_surface_t(bitPattern: 0x51))
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 5))
        return context
    }
}
