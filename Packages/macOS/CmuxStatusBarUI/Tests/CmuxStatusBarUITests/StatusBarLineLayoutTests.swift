import AppKit
import CmuxStatusBar
import CmuxStatusBarUI
import SwiftUI
import Testing

/// The bar sits under the whole window in ContentView's VStack, inside a root
/// ZStack that lays every child out at its widest child's width. A bar that
/// answers wider than it was offered therefore drags the sidebar, terminals and
/// titlebar out past both window edges, so it must answer exactly the offer.
@MainActor
@Suite("Status bar line layout")
struct StatusBarLineLayoutTests {
    private func width(of text: String, offered: CGFloat) -> CGFloat {
        let line = StatusBarLine(
            segments: [StatusBarSegment(link: nil, runs: [StatusBarRun(text: text)])],
            fontSize: 11,
            alignment: .leading,
            openLink: { _ in }
        )
        return NSHostingController(rootView: line).sizeThatFits(in: CGSize(width: offered, height: 22)).width
    }

    @Test func lineWiderThanTheWindowTakesOnlyTheOfferedWidth() {
        let usage = String(repeating: "Claude 42% | Codex 17% | Cursor 3% | ", count: 8)
        #expect(width(of: usage, offered: 400) == 400)
    }

    @Test func lineThatFitsFillsTheOfferedWidth() {
        #expect(width(of: "Claude 42%", offered: 400) == 400)
    }

    /// Links are buttons for keyboard and VoiceOver; a bordered macOS button
    /// would pad each one and the line would no longer read as one run of text.
    @Test func linkTakesTheSameWidthAsPlainText() {
        func fittingWidth(link: String?) -> CGFloat {
            let line = StatusBarLine(
                segments: [StatusBarSegment(link: link, runs: [StatusBarRun(text: "Codex 17%")])],
                fontSize: 11,
                alignment: .leading,
                openLink: { _ in }
            )
            return NSHostingView(rootView: line).fittingSize.width
        }
        #expect(fittingWidth(link: "cmux-action:codex") == fittingWidth(link: nil))
    }
}
