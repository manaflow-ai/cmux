#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Live rig report (PR #24650, 2026-10-24): with the Mac's grid at 120
/// columns and the phone narrower, htop rendered garbled on the phone (rows
/// mixing fragments of an earlier layout, ^L did not clear it) while vim
/// and Claude Code were clean. htop paints every meter row to the last
/// column and then updates cells in place by cursor address, so a mirror
/// whose grid is not exactly the Mac's (a column short wraps every full
/// row onto the next) or whose rows differ shows it at once.
///
/// Through the real Ghostty surface, sized the way the screen sizes it
/// (``TerminalHostGridLayout``) and fed through ``TerminalRowShift``: the
/// mirror's grid is the Mac's columns, and an htop-shaped paint at 120x39
/// reads back as a 120x39 terminal shows it.
@MainActor
@Suite(.serialized) struct TerminalHostGridSurfaceTests {
    static let hostColumns = 120
    static let hostRows = 39

    @MainActor final class Rig {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2000))
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 362, height: 1800))
        var shift = TerminalRowShift()

        init() {
            window.isHidden = false
            window.addSubview(surface)
        }

        var layout: TerminalHostGridLayout {
            TerminalHostGridLayout(viewportWidth: 362, cell: surface.cellSize, scale: window.screen.scale,
                                   hostColumns: TerminalHostGridSurfaceTests.hostColumns,
                                   hostRows: TerminalHostGridSurfaceTests.hostRows, visibleRows: 30)
        }

        /// The screen's sizing: the mirror takes the Mac's columns.
        func followHost() {
            surface.frame.size.width = layout.surfaceWidth
            surface.layoutIfNeeded()
        }

        var offset: Int { max(0, surface.grid.rows - TerminalHostGridSurfaceTests.hostRows) }

        func feed(_ text: String) async {
            let bytes = shift.filter(Data(text.utf8), offset: offset, remoteRows: TerminalHostGridSurfaceTests.hostRows)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                surface.feed(bytes, completion: { done.resume() })
            }
        }

        /// The TUI's rows: the top `hostRows` of the mirror, one string per row.
        var tuiRows: [String] {
            let text = surface.activeAreaText() ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Array((lines + Array(repeating: "", count: TerminalHostGridSurfaceTests.hostRows))
                .prefix(TerminalHostGridSurfaceTests.hostRows))
        }
    }

    /// One full-width row: `label` then a fill to the last column, ending in `|`.
    static func fullRow(_ label: String, fill: Character) -> String {
        let body = label + String(repeating: fill, count: hostColumns - label.count - 1)
        return body + "|"
    }

    /// An htop-shaped paint: alternate screen, its own margins, every row
    /// written to the last column by cursor address.
    static func paint(fill: Character) -> String {
        var out = "\u{1B}[?1049h\u{1B}[1;\(hostRows)r\u{1B}[H\u{1B}[2J"
        for row in 1...hostRows {
            out += "\u{1B}[\(row);1H" + fullRow(String(format: "%02d ", row), fill: fill)
        }
        return out + "\u{1B}[\(hostRows);1H"
    }

    @Test func theMirrorHasExactlyTheMacsColumns() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        try #require(rig.layout.phoneColumns < Self.hostColumns, "the phone is narrower than the Mac's grid")
        rig.followHost()
        #expect(rig.surface.grid.columns == Self.hostColumns)
    }

    @Test func anHtopPaintAtTheMacsGridReadsBackAsTheMacShowsIt() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        // The phone attached at its own width first (a shell), then the
        // Mac's grid arrived: the mirror follows it before htop's bytes.
        await rig.feed("\u{1B}c$ htop\r\n")
        rig.followHost()
        await rig.feed(Self.paint(fill: "a"))
        // In-place updates by cursor address, as htop's meters and list.
        await rig.feed("\u{1B}[5;10HCHANGED\u{1B}[39;100HLAST\u{1B}[1;\(Self.hostColumns)HZ")
        var expected = (1...Self.hostRows).map { Self.fullRow(String(format: "%02d ", $0), fill: "a") }
        func put(_ text: String, row: Int, column: Int) {
            var chars = Array(expected[row - 1])
            for (index, char) in text.enumerated() { chars[column - 1 + index] = char }
            expected[row - 1] = String(chars)
        }
        put("CHANGED", row: 5, column: 10)
        put("LAST", row: 39, column: 100)
        put("Z", row: 1, column: Self.hostColumns)
        let rows = rig.tuiRows
        for row in 0..<Self.hostRows {
            #expect(rows[row] == expected[row], "row \(row + 1)")
        }
    }

    /// The rig's failure: the Mac's grid arrived while the terminal page was
    /// out of a window (the phone was on the workspace list, or the tab was
    /// warm behind another one). The screen sized the mirror to the Mac's
    /// columns then, but the surface told Ghostty its size only while it had
    /// a window, and nothing told it again when the page came back: Ghostty
    /// kept the phone's ~49 columns inside a 120-column frame, so every
    /// htop row wrapped (the Command column landed in the next rows' first
    /// cells) and ^L's full repaint wrapped the same way.
    @Test func aGridChangeOutOfTheWindowStillReachesGhostty() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        let phoneColumns = rig.surface.grid.columns
        try #require(phoneColumns < Self.hostColumns)
        await rig.feed("\u{1B}c$ htop\r\n")
        // The page leaves the window; the Mac's grid arrives meanwhile.
        rig.surface.removeFromSuperview()
        rig.followHost()
        await rig.feed(Self.paint(fill: "b"))
        // The page is shown again.
        rig.window.addSubview(rig.surface)
        rig.window.layoutIfNeeded()
        #expect(rig.surface.grid.columns == Self.hostColumns, "Ghostty has the mirror's columns")
        let rows = rig.tuiRows
        for row in [0, 4, 38] {
            #expect(rows[row] == Self.fullRow(String(format: "%02d ", row + 1), fill: "b"), "row \(row + 1)")
        }
    }
}
#endif
