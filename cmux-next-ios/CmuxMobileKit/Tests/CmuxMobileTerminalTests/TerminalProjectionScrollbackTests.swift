// The projection (TerminalProjectingSession) and its FFI are iOS only, so
// these run on the kit job's iOS simulator leg, not under macOS swift test.
#if os(iOS)
import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-17: "how's the lean terminal view on phone? proven upholding
/// behaviour yet? headers left right end of terminal lines etc?"
///
/// The golden case `scrollback_reaches_line_one` on the phone's session: a
/// Mac pane of 120x24 that printed 3,000 lines (the golden's own lines),
/// projected at the phone's 54x38. The attach's replay paints a window (two
/// phone screens above the screen); the reader scrolling up asks for older
/// rows (`TerminalSession.loadOlderHistory()`) until line 1, the way the page
/// asks (TerminalViewController's `restoreReadingMark` and `didScroll`):
/// it records that it asked only once the call returns (`olderRowsAsked`),
/// waits for the reset that answers it, and keeps calling meanwhile as it
/// scrolls. The fleet's golden shots stopped at line 2950: the session sent
/// its reset inside the call (before the page recorded the ask) and answered
/// later calls true without sending one.
@MainActor
@Suite(.serialized) struct TerminalProjectionScrollbackTests {
    /// What the page holds: the text since the last reset, and whether it
    /// is waiting for the reset older rows come in.
    @MainActor final class Page {
        var text = ""
        var resets = 0
        var olderRowsAsked = false

        func take(_ event: TerminalSessionEvent) {
            guard case .output(let data) = event else { return }
            if data == TerminalReclaimHold.reset {
                resets += 1
                olderRowsAsked = false
                text = ""
            } else {
                text += String(decoding: data, as: UTF8.self)
            }
        }
    }

    /// The golden's lines (tests/golden.rs `scrollback_reaches_line_one`).
    static let lines: [String] = (1...3000).map { i in
        "line \(String(format: "%04d", i)) " + String(repeating: "pad ", count: i % 40)
    }

    private func projectionDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalPhoneProjection)
        return defaults
    }

    @Test func scrollingUpReachesLineOne() async {
        let mac = MacPaneMockSession(columns: 120, rows: 24, transcript: Self.lines)
        let session = TerminalSessionChoice.session(live: mac, mockDataEnabled: false, macName: "Mac", programName: "zsh", defaults: projectionDefaults())
        #expect(session is TerminalProjectingSession)
        let page = Page()
        session.resize(columns: 54, rows: 38)
        session.start { page.take($0) }
        #expect(page.text.contains("line 3000"), "the attach's replay holds the end")
        #expect(!page.text.contains("line 0001"), "the attach's replay is a window, not the whole scrollback")

        var loads = 0
        while loads < 20 {
            let resetsBefore = page.resets
            guard session.loadOlderHistory() else { break }
            let insideTheCall = page.resets - resetsBefore
            page.olderRowsAsked = true
            // The page keeps scrolling at the top while the reset is on its
            // way: those calls join the ask (true: the same reset follows).
            for _ in 0..<5 { #expect(session.loadOlderHistory(), "a call while older rows are on their way") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while page.olderRowsAsked, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(insideTheCall == 0, "load \(loads + 1): the reset came inside the call, before the page recorded its ask")
            #expect(!page.olderRowsAsked, "load \(loads + 1): the page asked for older rows and no reset followed")
            if page.olderRowsAsked { break }
            loads += 1
        }
        print("projection scrollback: \(loads) loads to line 1, \(page.resets) resets")
        #expect(page.text.contains("line 0001"), "the phone holds line 1 after \(loads) loads")
        #expect(page.text.contains("line 3000"))
        #expect(!session.loadOlderHistory(), "nothing older than line 1")
    }
}

#endif
