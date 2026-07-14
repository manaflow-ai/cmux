import CMUXMobileCore
@testable import CmuxMobileTerminal
import Testing

@Suite("Authoritative terminal grid state")
struct AuthoritativeTerminalGridStateTests {
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
                .init(row: 0, column: 0, text: "partial"),
            ]
        )

        #expect(state.apply(current) == .presented)
        #expect(state.apply(partial) == .needsFullSnapshot)
        #expect(state.frame == current)
    }

    private func frame(
        revision: UInt64,
        columns: Int,
        rows: [String]
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "surface",
            stateSeq: revision,
            renderRevision: revision,
            columns: columns,
            rows: rows.count,
            rowSpans: rows.enumerated().map { row, text in
                .init(row: row, column: 0, text: text)
            }
        )
    }
}
