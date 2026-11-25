import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Find through the Mac's `terminal-find`: pages decode, rows map onto the mirror, matches
/// older than the mirror wait for their history, and a daemon without the command is detected.
@Suite struct TerminalFindDaemonTests {
    private func reply(_ data: String) -> Data {
        Data(#"{"id":1,"ok":true,"data":\#(data)}"#.utf8)
    }

    @Test func aPageDecodesNewestFirst() throws {
        let page = try TerminalFindPage.decode(reply(#"""
        {"matches":[{"start":{"marker":90,"column":3},"end":{"marker":90,"column":7},"rows_from_bottom":10,"snippet":"a needle"},
                    {"start":{"marker":40,"column":0},"end":{"marker":41,"column":1},"rows_from_bottom":60,"snippet":"x"}],
         "next_before":40,"complete":false,"epoch":2,"restarted":false,"bottom":100}
        """#))
        #expect(page.hits.map(\.rowsFromBottom) == [10, 60])
        #expect(page.nextBefore == 40)
        #expect(page.epoch == 2)
        #expect(!page.complete)
    }

    @Test func aRefusedOrUnknownCommandIsUnsupported() {
        let refused = Data(#"{"error":"terminal-find is not available to a phone","error_code":"forbidden","id":1,"ok":false}"#.utf8)
        #expect(throws: TerminalFindError.refused("terminal-find is not available to a phone")) { try TerminalFindPage.decode(refused) }
        #expect(TerminalFindError.refused("terminal-find is not available to a phone").isUnsupported)
        #expect(TerminalFindError.refused("unknown command terminal-find").isUnsupported)
        #expect(!TerminalFindError.refused("unknown surface 9").isUnsupported)
    }

    @Test func theRequestCarriesOnlyTheTogglesThatAreOn() {
        let plain = TerminalFindRequest(query: "x", options: .init())
        #expect(Set(plain.fields.keys) == ["query"])
        let all = TerminalFindRequest(query: "x", options: .init(caseSensitive: true, wholeWord: true, regex: true), before: 5, epoch: 3)
        #expect(Set(all.fields.keys) == ["query", "case_sensitive", "whole_word", "regex", "before", "epoch"])
    }

    @Test func aTailMirrorMapsRowsFromTheBottom() {
        // The Mac holds 1,000 rows; the mirror the newest 300 (700 omitted).
        let map = TerminalFindRowMap(mirror: .init(omitted: 700, skipped: 0, windowRows: nil), mirrorRows: 300)
        #expect(map.daemonRows == 1_000)
        #expect(map.daemonRow(rowsFromBottom: 1) == 999)
        #expect(map.mirrorRow(forDaemonRow: 999) == 299)
        #expect(map.mirrorRow(forDaemonRow: 700) == 0)
        #expect(map.mirrorRow(forDaemonRow: 699) == nil)
    }

    @Test func aWindowMirrorHasAGapBeforeTheScreen() {
        // 5,000 rows on the Mac; the mirror holds history rows 1,000..<3,000 and the 40-row screen.
        let map = TerminalFindRowMap(mirror: .init(omitted: 1_000, skipped: 1_960, windowRows: 2_000), mirrorRows: 2_040)
        #expect(map.daemonRows == 5_000)
        #expect(map.mirrorRow(forDaemonRow: 1_500) == 500)
        #expect(map.mirrorRow(forDaemonRow: 3_500) == nil)
        #expect(map.mirrorRow(forDaemonRow: 4_999) == 2_039)
    }

    @Test func aMatchOlderThanTheMirrorIsKeptUnplacedUntilItsHistoryArrives() throws {
        let tail = TerminalFindRowMap(mirror: .init(omitted: 700, skipped: 0, windowRows: nil), mirrorRows: 300)
        let page = try TerminalFindPage.decode(reply(#"""
        {"matches":[{"start":{"marker":990,"column":2},"end":{"marker":990,"column":5},"rows_from_bottom":10,"snippet":"s"},
                    {"start":{"marker":100,"column":1},"end":{"marker":100,"column":4},"rows_from_bottom":900,"snippet":"s"}],
         "next_before":null,"complete":true,"epoch":1,"restarted":false,"bottom":1000}
        """#))
        var find = TerminalFindResults(daemonQuery: "s")
        find.append(page: page, map: tail, columns: 80)
        #expect(find.matches.count == 2)
        // Document order: the older first; the newest is selected ("2 of 2").
        #expect(find.selected == 1)
        #expect(find.matches[0].isLoaded == false)
        #expect(find.matches[1].segments == [TerminalLink.Segment(row: 290, start: 2, end: 5)])
        // The mirror now holds all 1,000 rows: the older match is laid on its row.
        find.remap(TerminalFindRowMap(mirror: .init(omitted: 0, skipped: 0, windowRows: nil), mirrorRows: 1_000), columns: 80)
        #expect(find.matches[0].segments == [TerminalLink.Segment(row: 100, start: 1, end: 4)])
        #expect(find.matches[1].segments == [TerminalLink.Segment(row: 990, start: 2, end: 5)])
    }

    @Test func laterPagesGoAboveAndKeepTheSelectedMatch() throws {
        let map = TerminalFindRowMap(mirror: .init(omitted: 0, skipped: 0, windowRows: nil), mirrorRows: 100)
        func page(_ markers: [Int], next: Int?) -> TerminalFindPage {
            TerminalFindPage(hits: markers.map { .init(start: .init(marker: $0, column: 0), end: .init(marker: $0, column: 1),
                                                       rowsFromBottom: 100 - $0, snippet: "") },
                             nextBefore: next, complete: next == nil, epoch: 1, restarted: false, bottom: 100, invalidPattern: nil)
        }
        var find = TerminalFindResults(daemonQuery: "q")
        find.append(page: page([90, 80], next: 80), map: map, columns: 80)
        #expect(find.selectedMatch?.row == 90)
        find.step(forward: false)
        #expect(find.selectedMatch?.row == 80)
        find.append(page: page([50, 40], next: nil), map: map, columns: 80)
        #expect(find.matches.map(\.row) == [40, 50, 80, 90])
        #expect(find.selectedMatch?.row == 80)
        #expect(find.isComplete)
    }
}

#if os(iOS)
import CmuxMobileLinkFFI

@Suite struct TerminalFindProjectionTests {
    private func page(_ hits: [TerminalFindPage.Hit]) -> TerminalFindPage {
        TerminalFindPage(hits: hits, nextBefore: nil, complete: true, epoch: 1, restarted: false, bottom: 3, invalidPattern: nil)
    }

    @Test func hitsMoveOntoTheRewrappedRows() {
        // The Mac's `abcdefghij`(wrapped) / `klmno` / `xyz` at 4 phone columns: j is the 3rd row
        // from the bottom at column 1; m the 2nd at column 0 (`locate_follows_a_host_cell_through_the_rewrap`).
        let projection = TerminalProjection(hostCols: 10, hostRows: 3)
        _ = projection.setViewport(cols: 4, rows: 3)
        _ = projection.feed(bytes: Data("abcdefghijklmno\r\nxyz".utf8), paint: true)
        let hit = TerminalFindPage.Hit(
            start: .init(marker: 10, column: 9), end: .init(marker: 10, column: 9), rowsFromBottom: 3, snippet: "j")
        let moved = TerminalProjectingSession.relocated(page([hit])) { rows, column in
            projection.locate(hostFromBottom: UInt64(rows), hostColumn: UInt32(column))
                .map { (Int($0.fromBottom), Int($0.column)) }
        }
        #expect(moved.hits.count == 1)
        #expect(moved.hits.first?.rowsFromBottom == 3)
        #expect(moved.hits.first?.start.column == 1)
        #expect(moved.hits.first?.end.marker == 0)
    }

    @Test func aMatchAcrossHostRowsKeepsItsPhoneSpanAndUnheldHitsGo() {
        let across = TerminalFindPage.Hit(
            start: .init(marker: 5, column: 8), end: .init(marker: 6, column: 1), rowsFromBottom: 4, snippet: "ab")
        let old = TerminalFindPage.Hit(
            start: .init(marker: 1, column: 0), end: .init(marker: 1, column: 0), rowsFromBottom: 900, snippet: "z")
        let moved = TerminalProjectingSession.relocated(page([across, old])) { rows, column in
            rows > 100 ? nil : (rows * 2, column)
        }
        #expect(moved.hits.count == 1)
        #expect(moved.hits.first?.rowsFromBottom == 8)
        #expect(moved.hits.first?.end.marker == 2)
        #expect(moved.hits.first?.start.column == 8 && moved.hits.first?.end.column == 1)
    }
}
#endif
