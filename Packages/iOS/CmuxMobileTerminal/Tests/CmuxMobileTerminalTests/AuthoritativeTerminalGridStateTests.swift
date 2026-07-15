import CMUXMobileCore
@testable import CmuxMobileTerminal
import Testing

@Suite("Authoritative terminal grid state")
struct AuthoritativeTerminalGridStateTests {
    @Test func blinkingTextAlternatesWhileSteadyTextRemainsVisible() {
        #expect(AuthoritativeTerminalGridView.shouldDrawText(
            styleBlinks: true,
            blinkPhaseVisible: true
        ))
        #expect(!AuthoritativeTerminalGridView.shouldDrawText(
            styleBlinks: true,
            blinkPhaseVisible: false
        ))
        #expect(AuthoritativeTerminalGridView.shouldDrawText(
            styleBlinks: false,
            blinkPhaseVisible: false
        ))
    }

    @Test("renderer suppression starts before the first authoritative frame commits")
    func rendererSuppressionCoversPrecommitGeometry() {
        #expect(GhosttySurfaceView.shouldHideRenderer(
            isRenderDispatchSuppressed: true,
            isAuthoritativeGridPresented: false
        ))
        #expect(GhosttySurfaceView.shouldHideRenderer(
            isRenderDispatchSuppressed: false,
            isAuthoritativeGridPresented: true
        ))
        #expect(!GhosttySurfaceView.shouldHideRenderer(
            isRenderDispatchSuppressed: false,
            isAuthoritativeGridPresented: false
        ))
    }

    @Test("authoritative presentation leaves producer geometry under Mac ownership")
    func authoritativePresentationDoesNotReportPhoneViewport() {
        #expect(!GhosttySurfaceView.shouldReportNaturalViewport(
            authoritativeGridActive: true
        ))
        #expect(GhosttySurfaceView.shouldReportNaturalViewport(
            authoritativeGridActive: false
        ))
    }

    @Test("a resized full frame replaces every row from the previous width")
    func resizedFrameReplacesThePreviousGridAtomically() throws {
        var state = AuthoritativeTerminalGridState(surfaceID: "surface")
        let oldWidth = try frame(
            revision: 10,
            columns: 8,
            rows: ["old-one", "old-two"]
        )
        let newWidth = try frame(
            revision: 11,
            columns: 12,
            rows: ["new-row-one", "new-row-two"]
        )

        #expect(state.apply(oldWidth) == .presented)
        #expect(state.apply(newWidth) == .presented)
        #expect(state.frame == newWidth)
        #expect(state.frame?.columns == 12)
        #expect(state.frame?.plainRows() == ["new-row-one", "new-row-two"])
    }

    @Test("an older revision cannot overwrite a newer resized frame")
    func staleFrameIsRejected() throws {
        var state = AuthoritativeTerminalGridState(surfaceID: "surface")
        let current = try frame(
            revision: 21,
            columns: 12,
            rows: ["current-one", "current-two"]
        )
        let stale = try frame(
            revision: 20,
            columns: 8,
            rows: ["stale-1", "stale-2"]
        )

        #expect(state.apply(current) == .presented)
        #expect(state.apply(stale) == .ignoredStale)
        #expect(state.frame == current)
    }

    @Test("a newer producer epoch accepts a reset revision and fences the old epoch")
    func producerReplacementResetsRevisionOrdering() throws {
        var state = AuthoritativeTerminalGridState(surfaceID: "surface")
        let oldProducer = try frame(epoch: 7, revision: 90, columns: 8, rows: ["old"])
        let replacement = try frame(epoch: 8, revision: 1, columns: 8, rows: ["new"])
        let delayedOldProducer = try frame(epoch: 7, revision: 91, columns: 8, rows: ["late"])

        #expect(state.apply(oldProducer) == .presented)
        #expect(state.apply(replacement) == .presented)
        #expect(state.apply(delayedOldProducer) == .ignoredStale)
        #expect(state.frame == replacement)
    }

    @Test("an incomplete frame never replaces the visible full snapshot")
    func partialFrameRequiresAFullSnapshot() throws {
        var state = AuthoritativeTerminalGridState(surfaceID: "surface")
        let current = try frame(
            revision: 30,
            columns: 12,
            rows: ["complete-one", "complete-two"]
        )
        let partial = try MobileTerminalRenderGridFrame(
            surfaceID: "surface",
            stateSeq: 30,
            renderRevision: 31,
            columns: 12,
            rows: 2,
            full: false,
            clearedRows: [0],
            rowSpans: [
                .init(row: 0, column: 0, text: "partial")
            ]
        )

        #expect(state.apply(current) == .presented)
        #expect(state.apply(partial) == .needsFullSnapshot)
        #expect(state.frame == current)
    }

    @Test("a replay generation resets ordering without clearing the visible frame")
    func replayGenerationPreservesLastGoodFrame() throws {
        var state = AuthoritativeTerminalGridState(surfaceID: "surface")
        let current = try frame(
            revision: 40,
            columns: 16,
            rows: ["last-good-one", "last-good-two"]
        )
        let replay = try frame(
            revision: 1,
            columns: 16,
            rows: ["replayed-one", "replayed-two"]
        )

        #expect(state.apply(current) == .presented)
        state.beginReplay(surfaceID: "surface")

        #expect(state.frame == current)
        #expect(state.classify(replay) == .presented)
        #expect(state.commit(replay) == .presented)
        #expect(state.frame == replay)
    }

    @Test("stale and invalid frames are rejected before viewport mutation")
    func admissionPrecedesViewportPolicy() throws {
        var state = AuthoritativeTerminalGridState(surfaceID: "surface")
        let current = try frame(
            revision: 50,
            columns: 12,
            rows: ["current-one", "current-two"]
        )
        let stale = try frame(
            revision: 49,
            columns: 8,
            rows: ["stale-1", "stale-2"]
        )
        let wrongSurface = try MobileTerminalRenderGridFrame(
            surfaceID: "replacement",
            stateSeq: 51,
            renderRevision: 51,
            columns: 20,
            rows: 1,
            rowSpans: [.init(row: 0, column: 0, text: "wrong surface")]
        )

        #expect(state.apply(current) == .presented)

        let staleAdmission = state.classify(stale)
        #expect(staleAdmission == .ignoredStale)
        #expect(!staleAdmission.allowsViewportMutation)
        #expect(state.frame == current)

        let invalidAdmission = state.classify(wrongSurface)
        #expect(invalidAdmission == .needsFullSnapshot)
        #expect(!invalidAdmission.allowsViewportMutation)
        #expect(state.frame == current)
    }

    private func frame(
        epoch: UInt64 = 1,
        revision: UInt64,
        columns: Int,
        rows: [String]
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "surface",
            stateSeq: revision,
            producerEpoch: epoch,
            renderRevision: revision,
            columns: columns,
            rows: rows.count,
            rowSpans: rows.enumerated().map { row, text in
                .init(row: row, column: 0, text: text)
            }
        )
    }
}
