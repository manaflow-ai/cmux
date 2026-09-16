import CmuxTerminalCore
import Testing

struct TerminalPortalResizePhaseTests {
    @Test func nativeEndDoesNotReleaseBeforeGeometryCommit() {
        var phase = TerminalPortalResizePhase()
        phase.begin()
        phase.requestEnd()

        let acceptsNativeEnd = phase.observeNativeResize(active: false)
        #expect(acceptsNativeEnd)
        #expect(phase.isEnding)
        #expect(phase.defersRenderer)

        phase.commitEnd(nativeResizeActive: false)
        #expect(!phase.isEnding)
        #expect(!phase.defersRenderer)
    }

    @Test func lateNativeCallbacksCannotReopenACompletedResize() {
        var phase = TerminalPortalResizePhase()
        phase.begin()
        phase.requestEnd()
        phase.commitEnd(nativeResizeActive: true)

        let acceptsLateTick = phase.observeNativeResize(active: true)
        #expect(!acceptsLateTick)
        #expect(!phase.defersRenderer)
        let acceptsNativeEnd = phase.observeNativeResize(active: false)
        #expect(acceptsNativeEnd)
        #expect(!phase.defersRenderer)

        let acceptsNewResize = phase.observeNativeResize(active: true)
        #expect(acceptsNewResize)
        #expect(phase.defersRenderer)
    }

    @Test func explicitStartSupersedesAnOldNativeEndSignal() {
        var phase = TerminalPortalResizePhase()
        phase.begin()
        phase.requestEnd()
        phase.commitEnd(nativeResizeActive: true)
        phase.begin()

        let acceptsNewResize = phase.observeNativeResize(active: true)
        #expect(acceptsNewResize)
        #expect(phase.defersRenderer)
        #expect(!phase.isEnding)
    }

    @Test func retirementReleasesAnUnfinishedResize() {
        var phase = TerminalPortalResizePhase()
        phase.begin()
        phase.requestEnd()
        phase.reset()

        #expect(!phase.defersRenderer)
        #expect(!phase.isEnding)
        let acceptsOrdinaryLayout = phase.observeNativeResize(active: false)
        #expect(acceptsOrdinaryLayout)
    }
}
