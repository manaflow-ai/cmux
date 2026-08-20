import Foundation
import Testing
import CmuxTerminalCore
import GhosttyKit

private final class CallbackMetadataSurfaceController: TerminalSurfaceControlling {
    let surfaceId: UUID
    let owningTabId: UUID
    var runtimeSurfacePointer: ghostty_surface_t?

    init(
        surfaceId: UUID = UUID(),
        owningTabId: UUID = UUID(),
        runtimeSurfacePointer: ghostty_surface_t? = nil
    ) {
        self.surfaceId = surfaceId
        self.owningTabId = owningTabId
        self.runtimeSurfacePointer = runtimeSurfacePointer
    }
}

private final class CallbackMetadataSurfaceHost: TerminalSurfaceHosting {
    var hostedTabId: UUID?
    var attachedSurfaceController: (any TerminalSurfaceControlling)?
}

@Suite struct GhosttySurfaceCallbackMetadataTests {
    @Test func capturesImmutableTitleAndSourceIdentity() {
        let controller = CallbackMetadataSurfaceController()
        let sourceSurfaceIdentifier = ObjectIdentifier(controller)
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: CallbackMetadataSurfaceHost(),
            surfaceController: controller,
            terminalLifecycleID: UUID(),
            titleOverride: "Testare-B"
        )

        #expect(context.sourceSurfaceIdentifier == sourceSurfaceIdentifier)
        #expect(context.titleOverride == "Testare-B")
    }

    @Test func replacementRuntimeKeepsItsOwnTitleSnapshot() {
        let controller = CallbackMetadataSurfaceController()
        let host = CallbackMetadataSurfaceHost()
        let first = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID(),
            titleOverride: "Testare-A"
        )
        let replacement = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID(),
            titleOverride: "Testare-B"
        )

        #expect(first.titleOverride == "Testare-A")
        #expect(replacement.titleOverride == "Testare-B")
        #expect(first.terminalLifecycleID != replacement.terminalLifecycleID)
    }
}
