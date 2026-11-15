#if os(iOS) && DEBUG
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-15: "i meant previously there was the thing that stopped the
/// resizing when you closed the ios built in keyboard". The soft keyboard
/// coming or going never resizes the Mac's terminal: each resize resets the
/// phone's mirror and makes a full-screen app (Claude Code, Codex, vim) redraw,
/// which reads as the content jumping on every keyboard tap (#41895, taken
/// back by #42760). Covers the standalone terminal, the embedded terminal and
/// a workspace tab's page (`TerminalTabPage`, the terminal face of the
/// Chat | Terminal control too).
@MainActor
@Suite(.serialized) struct TerminalKeyboardNoResizeTests {
    typealias Area = TerminalTUIAreaTests

    /// Longer than `TerminalResizeSettle.settle`: a size the keyboard caused
    /// would have reached the session by then.
    static func pastTheSettle() async throws {
        try await Task.sleep(for: TerminalResizeSettle.settle * 2) // test: outlast the resize debounce
    }

    /// Three keyboard show and hide rounds; the rows sent to the session
    /// before and after must be the same, with no resize in between.
    static func expectNoKeyboardResize(_ page: Area.Page, _ state: String) async throws {
        try await pastTheSettle()
        let before = page.session.resizes
        let sentBefore = page.screen.model.ptyResizesSent
        try #require(!before.isEmpty, "\(state): the page never claimed its grid")
        for round in 0..<3 {
            Area.keyboard(page, height: 336)
            try await pastTheSettle()
            #expect(page.session.resizes == before, "\(state), round \(round): showing the keyboard resized the Mac's terminal \(before) -> \(page.session.resizes). \(page.screen.debugState)")
            Area.keyboard(page, height: 0)
            try await pastTheSettle()
            #expect(page.session.resizes == before, "\(state), round \(round): closing the keyboard resized the Mac's terminal \(before) -> \(page.session.resizes). \(page.screen.debugState)")
        }
        #expect(page.screen.model.ptyResizesSent == sentBefore, "\(state): \(page.screen.model.ptyResizesSent - sentBefore) resizes for the keyboard")
    }

    @Test func theKeyboardNeverResizesAStandaloneTerminal() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Area.open(.standalone)
        defer { page.close() }
        try await Self.expectNoKeyboardResize(page, "standalone")
    }

    @Test func theKeyboardNeverResizesAnEmbeddedTerminal() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Area.open(.embedded)
        defer { page.close() }
        try await Self.expectNoKeyboardResize(page, "embedded")
    }

    /// The workspace tab's page, which the Chat | Terminal control shows on
    /// its terminal face.
    @Test func theKeyboardNeverResizesATerminalTab() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Area.openTab(hostGrid: false)
        defer { page.close() }
        try await Self.expectNoKeyboardResize(page, "tab page")
    }
}
#endif
