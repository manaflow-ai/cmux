#if os(iOS) && DEBUG
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-15: "i meant previously there was the thing that stopped the
/// resizing when you closed the ios built in keyboard", then "just... add the
/// thing? add the top exception? why roll the whole thing back". The soft
/// keyboard coming or going never resizes the Mac's terminal: each resize
/// resets the phone's mirror and makes a full-screen app (Claude Code, Codex,
/// vim) redraw, which reads as the content jumping on every keyboard tap
/// (#41895, taken back by #42760). With the keyboard up, the app's first
/// rows (its header) stay on screen, and so does the cursor's row. Covers the
/// standalone terminal, the embedded terminal and a workspace tab's page
/// (`TerminalTabPage`, the terminal face of the Chat | Terminal control too).
@MainActor
@Suite(.serialized) struct TerminalKeyboardNoResizeTests {
    typealias Area = TerminalTUIAreaTests

    /// Longer than `TerminalResizeSettle.settle`: a size the keyboard caused
    /// would have reached the session by then.
    static func pastTheSettle() async throws {
        try await Task.sleep(for: TerminalResizeSettle.settle * 2) // test: outlast the resize debounce
    }

    /// Three keyboard show and hide rounds; the rows sent to the session
    /// before and after must be the same, with no resize in between. With the
    /// keyboard up, `keyboardUp` checks the page.
    static func expectNoKeyboardResize(_ page: Area.Page, _ state: String,
                                       keyboardUp: (Area.Page, String) throws -> Void = { _, _ in }) async throws {
        try await pastTheSettle()
        // The page's claim settled: the app draws in those rows.
        page.session.placeInputOnLastRow()
        try await pastTheSettle()
        page.screen.view.setNeedsLayout()
        page.screen.view.layoutIfNeeded()
        let before = page.session.resizes
        let sentBefore = page.screen.model.ptyResizesSent
        try #require(!before.isEmpty, "\(state): the page never claimed its grid")
        for round in 0..<3 {
            Area.keyboard(page, height: 336)
            try await pastTheSettle()
            #expect(page.session.resizes == before, "\(state), round \(round): showing the keyboard resized the Mac's terminal \(before) -> \(page.session.resizes). \(page.screen.debugState)")
            try keyboardUp(page, "\(state), round \(round), keyboard up")
            Area.keyboard(page, height: 0)
            try await pastTheSettle()
            #expect(page.session.resizes == before, "\(state), round \(round): closing the keyboard resized the Mac's terminal \(before) -> \(page.session.resizes). \(page.screen.debugState)")
            #expect(page.screen.tuiHeader.isHidden, "\(state), round \(round): the header stays pinned with the keyboard down. \(page.screen.debugState)")
        }
        #expect(page.screen.model.ptyResizesSent == sentBefore, "\(state): \(page.screen.model.ptyResizesSent - sentBefore) resizes for the keyboard")
    }

    @Test func theKeyboardNeverResizesAStandaloneTerminal() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Area.open(.standalone, cursorAtBottom: true)
        defer { page.close() }
        try await Self.expectNoKeyboardResize(page, "standalone", keyboardUp: Area.expectHeaderAndCursorVisible)
    }

    @Test func theKeyboardNeverResizesAnEmbeddedTerminal() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Area.open(.embedded, cursorAtBottom: true)
        defer { page.close() }
        try await Self.expectNoKeyboardResize(page, "embedded", keyboardUp: Area.expectHeaderAndCursorVisible)
    }

    /// The workspace tab's page, which the Chat | Terminal control shows on
    /// its terminal face.
    @Test func theKeyboardNeverResizesATerminalTab() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Area.openTab(hostGrid: false, cursorAtBottom: true)
        defer { page.close() }
        try await Self.expectNoKeyboardResize(page, "tab page", keyboardUp: Area.expectHeaderAndCursorVisible)
    }

    /// vim on line 1 (the cursor in the app's first rows): no header, the
    /// grid's top is shown as it is, and still no resize.
    @Test func aCursorOnTheFirstRowsShowsTheTopWithoutAHeader() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Area.open(.standalone)
        defer { page.close() }
        try await Self.expectNoKeyboardResize(page, "standalone, cursor on row 2") { page, state in
            try Area.expectHeaderAndCursorVisible(page, state)
            #expect(page.screen.tuiHeader.isHidden, "\(state): a header over the cursor's own rows. \(page.screen.debugState)")
        }
    }
}
#endif
