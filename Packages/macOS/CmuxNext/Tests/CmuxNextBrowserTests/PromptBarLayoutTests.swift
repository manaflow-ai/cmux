import AppKit
import Testing
@testable import CmuxNextBrowser

/// The prompt bar's message wraps at the room the bar has, never at the
/// width a narrow earlier layout left behind (the 2026-10-05 nxbp11-v1
/// proof showed the automatic-downloads question one character per line).
@MainActor
@Suite struct PromptBarLayoutTests {
    /// The bar in a container placed as the browser chrome places it (top,
    /// centered, an inset from the leading edge).
    private func host(_ bar: PromptBarView, width: CGFloat) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
        ])
        return container
    }

    @Test func aQuestionShownInANarrowPassWrapsAtTheBarRoomOnceWide() {
        let bar = PromptBarView()
        let container = host(bar, width: 40)
        bar.show(BrowserPrompt(kind: .permission(.automaticDownloads), origin: "http://127.0.0.1:55084") { _ in })
        container.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        container.setFrameSize(NSSize(width: 900, height: 600))
        container.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        #expect(bar.messageLineCount <= 2, "the question wraps at the bar's room, not at the narrow first pass")
    }
}
