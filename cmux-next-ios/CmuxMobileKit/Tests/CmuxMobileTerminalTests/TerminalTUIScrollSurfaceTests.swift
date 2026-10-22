#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// T-SCROLL-12 through the real Ghostty surface in mirror mode: the phone's
/// wheel goes through Ghostty's own encoder, so the app gets what Ghostty
/// sends on a Mac trackpad: SGR wheel reports when it asked for the mouse
/// (DECSET 1000 + 1006), cursor keys on the alternate screen with alternate
/// scroll (DECSET 1007, Ghostty's default), and nothing otherwise.
@MainActor
@Suite(.serialized) struct TerminalTUIScrollSurfaceTests {
    /// A mirror surface in a window, its output fed and its input collected.
    @MainActor final class Rig {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        var sent = Data()

        init() {
            window.isHidden = false
            window.addSubview(surface)
            surface.onInput = { [weak self] data in self?.sent.append(data) }
        }

        func feed(_ text: String) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                surface.feed(Data(text.utf8), completion: { done.resume() })
            }
        }

        /// A wheel of `rows` rows at the middle of `cell` (column, row).
        func wheel(rows: Double, column: Int, row: Int) {
            let size = surface.cellSize
            let point = CGPoint(x: (Double(column) + 0.5) * size.width, y: (Double(row) + 0.5) * size.height)
            surface.scrollWheel(at: point, deltaY: rows * size.height, momentum: .none)
        }

        var text: String { String(decoding: sent, as: UTF8.self) }
    }

    @Test func aMouseReportingAppGetsSGRWheelReportsAtTheFinger() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        rig.sent = Data()
        rig.wheel(rows: 3, column: 3, row: 5)
        #expect(rig.text == String(repeating: "\u{1b}[<64;4;6M", count: 3))
        rig.sent = Data()
        rig.wheel(rows: -2, column: 0, row: 0)
        #expect(rig.text == String(repeating: "\u{1b}[<65;1;1M", count: 2))
    }

    @Test func theAlternateScreenGetsArrowsByDefault() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h")
        rig.sent = Data()
        rig.wheel(rows: 2, column: 1, row: 1)
        #expect(rig.text == "\u{1b}[A\u{1b}[A")
        rig.sent = Data()
        rig.wheel(rows: -1, column: 1, row: 1)
        #expect(rig.text == "\u{1b}[B")
    }

    @Test func applicationCursorKeysSendSS3Arrows() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1h")
        rig.sent = Data()
        rig.wheel(rows: 1, column: 1, row: 1)
        #expect(rig.text == "\u{1b}OA")
    }

    @Test func alternateScrollOffSendsNothing() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1007l")
        rig.sent = Data()
        rig.wheel(rows: 4, column: 1, row: 1)
        #expect(rig.sent.isEmpty)
    }

    @Test func lessThanARowWaitsForMore() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h")
        rig.sent = Data()
        rig.wheel(rows: 0.6, column: 1, row: 1)
        #expect(rig.sent.isEmpty)
        rig.wheel(rows: 0.6, column: 1, row: 1)
        #expect(rig.text == "\u{1b}[A")
    }
}
#endif
