import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct OutputEventTests {
    @Test func rawBytesCarriesData() {
        let ev = OutputEvent.rawBytes(Data([0x41, 0x42]), seq: 1)
        if case .rawBytes(let d, let s) = ev {
            #expect(d == Data([0x41, 0x42]))
            #expect(s == 1)
        } else {
            Issue.record("not rawBytes")
        }
    }

    @Test func cellsSnapshotCarriesGrid() {
        let g = CellGrid(
            cols: 1, rows: 1, altScreen: false, title: nil,
            cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
            semanticAvailable: false, rowsData: []
        )
        let ev = OutputEvent.cellsSnapshot(g, seq: 42)
        if case .cellsSnapshot(_, let s) = ev {
            #expect(s == 42)
        } else {
            Issue.record("not cells")
        }
    }

    @Test func gapCarriesSeq() {
        let ev = OutputEvent.gap(seq: 7)
        if case .gap(let s) = ev {
            #expect(s == 7)
        } else {
            Issue.record("not gap")
        }
    }

    @Test func subscriptionOptionsHoldLastEventID() {
        let opts = StreamSubscriptionOptions(handle: .uuid(UUID()), mode: .raw, lastEventID: 99)
        #expect(opts.lastEventID == 99)
        #expect(opts.mode == .raw)
    }

    @Test func streamModeWireValuesAreLowercase() throws {
        let raw = try JSONEncoder().encode(StreamMode.raw)
        let cells = try JSONEncoder().encode(StreamMode.cells)
        #expect(String(decoding: raw, as: UTF8.self) == "\"raw\"")
        #expect(String(decoding: cells, as: UTF8.self) == "\"cells\"")
    }
}
