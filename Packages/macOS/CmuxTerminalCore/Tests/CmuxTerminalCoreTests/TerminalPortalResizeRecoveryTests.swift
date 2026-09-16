import CmuxTerminalCore
import Testing

struct TerminalPortalResizeRecoveryTests {
    @Test func activeDividerKeepsPublicationDeferredUntilItsOwnEnd() {
        var phase = TerminalPortalResizePhase()
        phase.begin()
        let acceptsGeometry1 = phase.observeNativeResize(active: false, interactiveResizeActive: true)
        #expect(acceptsGeometry1)
        #expect(phase.defersRenderer)
        #expect(!phase.isEnding)
        let acceptsGeometry2 = phase.observeNativeResize(active: false, interactiveResizeActive: false)
        #expect(acceptsGeometry2)
        #expect(phase.isEnding)
        phase.commitEnd(nativeResizeActive: false)
        #expect(!phase.defersRenderer)
    }

    @Test func observedResizeEndSchedulesFinalGeometryWithoutNotification() {
        var phase = TerminalPortalResizePhase()
        let acceptsGeometry3 = phase.observeNativeResize(active: true)
        #expect(acceptsGeometry3)
        #expect(phase.defersRenderer)
        // Reparenting can remove a view before its end-live-resize callback.
        // A later pane-layout event must finish the observed interaction.
        let acceptsGeometry4 = phase.observeNativeResize(active: false)
        #expect(acceptsGeometry4)
        #expect(phase.isEnding)
        #expect(phase.defersRenderer)
        phase.commitEnd(nativeResizeActive: false)
        #expect(!phase.defersRenderer)
        let acceptsGeometry5 = phase.observeNativeResize(active: false)
        #expect(acceptsGeometry5)
        #expect(!phase.defersRenderer)
    }
}
