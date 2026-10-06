import AppKit
@testable import CmuxNextApp
@testable import CmuxNextTabs
import Testing

/// Switching a pane to content that has not painted (an agent page, which is
/// transparent until its first frame) keeps the outgoing content on screen
/// until it paints, instead of an empty pane (#17485, New Tab blank).
@MainActor
@Suite(.serialized)
struct PanePaintHoldTests {
    final class Unpainted: NSView, PaneFirstPaintGated {
        var painted = false
        private var waiters: [() -> Void] = []
        var awaitsFirstPaint: Bool { !painted }
        func whenFirstPainted(_ body: @escaping () -> Void) {
            if painted { body() } else { waiters.append(body) }
        }
        func paint() {
            painted = true
            waiters.forEach { $0() }
            waiters = []
        }
    }

    private func pane() -> PaneContentView {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "t")], selectedID: TabID("t0"))
        let pane = PaneContentView(stripModel: model)
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    @Test func theOutgoingContentStaysUntilTheNewOnePaints() {
        let pane = pane()
        let terminal = NSView()
        pane.show(terminal)
        let agent = Unpainted()
        pane.show(agent)
        #expect(pane.content === agent)
        #expect(terminal.superview === pane.contentHost)
        #expect(agent.alphaValue == 0)
        #expect(pane.contentHost.subviews.last === agent)

        agent.paint()
        #expect(terminal.superview == nil)
        #expect(agent.alphaValue == 1)
    }

    @Test func paintedContentReplacesAtOnce() {
        let pane = pane()
        let terminal = NSView()
        pane.show(terminal)
        let agent = Unpainted()
        agent.painted = true
        pane.show(agent)
        #expect(terminal.superview == nil)
        #expect(agent.alphaValue == 1)
    }

    @Test func anotherSwitchEndsTheHold() {
        let pane = pane()
        let first = NSView()
        pane.show(first)
        let agent = Unpainted()
        pane.show(agent)
        let other = NSView()
        pane.show(other)
        #expect(first.superview == nil)
        #expect(agent.alphaValue == 1)
        #expect(pane.content === other)
    }

    @Test func aPageThatNeverPaintsShowsAfterTheLimit() async throws {
        let pane = pane()
        let terminal = NSView()
        pane.show(terminal)
        let agent = Unpainted()
        pane.show(agent)
        try await Task.sleep(for: PanePaintHold.limit + .milliseconds(200))
        #expect(terminal.superview == nil)
        #expect(agent.alphaValue == 1)
    }
}
