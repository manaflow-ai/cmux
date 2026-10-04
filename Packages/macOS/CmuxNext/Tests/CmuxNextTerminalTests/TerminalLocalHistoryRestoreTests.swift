import AppKit
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import Foundation
import GhosttyNextKit
import Testing

/// S2c: a READY cut at the owner's resize restores on the viewer with the
/// viewer's own history, reflowed by Ghostty to the new grid, when it
/// matches the owner's check; otherwise the READY restores without history
/// and the viewer asks for READY + history.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalLocalHistoryRestoreTests {
    /// 300 lines; every third one soft-wraps at 40 columns.
    private static let output: [Data] = (0..<300).map { index in
        let line = index % 3 == 0 ? "row \(index) " + String(repeating: "w", count: 60) : "row \(index)"
        return Data("\(line)\r\n".utf8)
    }

    private func pair(skipping skipped: Int? = nil) async throws
        -> (owner: TerminalSession, viewer: TerminalSession, viewerIO: ScriptedTerminalIO) {
        let (owner, ownerIO) = try LiveTerminal.session(manual: true)
        let (viewer, viewerIO) = try LiveTerminal.session()
        ownerIO.send(.resize(cols: 40, rows: 10))
        viewerIO.send(.resize(cols: 40, rows: 10))
        for (index, chunk) in Self.output.enumerated() {
            ownerIO.send(.output(chunk))
            if index != skipped { viewerIO.send(.output(chunk)) }
        }
        ownerIO.send(.output(Data("END$ ".utf8)))
        viewerIO.send(.output(Data("END$ ".utf8)))
        await LiveTerminal.until(owner) { owner.surfaceView.viewportText()?.contains("END$") == true }
        await LiveTerminal.until(viewer) { viewer.surfaceView.viewportText()?.contains("END$") == true }
        // The owner reflows its grid (a MANUAL surface reflows on set_grid).
        ownerIO.send(.resize(cols: 25, rows: 10))
        await LiveTerminal.until(owner) { owner.diagnostics.grid == TerminalGridSize(columns: 25, rows: 10) }
        return (owner, viewer, viewerIO)
    }

    private func localReady(_ owner: TerminalSession) async throws -> (Data, TerminalLocalHistory) {
        let ready = try await LiveTerminal.encodeReady(owner)
        let check = try await LiveTerminal.historyCheck(owner)
        return (ready, TerminalLocalHistory(columns: 25, rows: 10, historyRows: check.rows, digest: check.digest))
    }

    @Test func aMatchingViewerKeepsItsReflowedHistory() async throws {
        let (owner, viewer, viewerIO) = try await pair()
        defer { owner.close(); viewer.close() }
        let surface = viewer.surfaceView
        let (ready, local) = try await localReady(owner)
        #expect(local.historyRows > 0)
        viewerIO.send(.snapshot(ready, phase: .readyLocalHistory(local)))
        await LiveTerminal.until(viewer) { viewer.diagnostics.restoredSnapshots == 1 }
        #expect(viewer.surfaceView === surface)
        #expect(viewer.diagnostics.localHistoryMismatches == 0)
        #expect(viewer.diagnostics.grid == TerminalGridSize(columns: 25, rows: 10))
        #expect(LiveTerminal.screenText(viewer) == LiveTerminal.screenText(owner))
        #expect(LiveTerminal.screenText(viewer).contains("row 0 "))
    }

    /// The viewer missed one chunk: its history differs from the owner's, so
    /// it keeps none of it and shows only the owner's READY (whose first page
    /// here holds every owner row, the missed one included), and counts a
    /// mismatch (the IO then asks for READY + history).
    @Test func aDivergedViewerDropsItsHistoryAndAsksForIt() async throws {
        let (owner, viewer, viewerIO) = try await pair(skipping: 120)
        defer { owner.close(); viewer.close() }
        let (ready, local) = try await localReady(owner)
        viewerIO.send(.snapshot(ready, phase: .readyLocalHistory(local)))
        await LiveTerminal.until(viewer) { viewer.diagnostics.localHistoryMismatches == 1 }
        #expect(viewer.diagnostics.localHistoryMismatches == 1)
        #expect(viewer.surfaceView.viewportText() == owner.surfaceView.viewportText())
        #expect(LiveTerminal.screenText(viewer).contains("row 120 "))
        #expect(LiveTerminal.screenText(viewer) == LiveTerminal.screenText(owner))
    }
}
