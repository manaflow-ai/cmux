import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPages
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
        try await Task.sleep(for: PanePaintHold.limit + .seconds(1))
        #expect(terminal.superview == nil)
        #expect(agent.alphaValue == 1)
    }
}

extension PanePaintHoldTests {
    /// An outgoing view that hid itself when withdrawn shows nothing to keep.
    @Test func hiddenOutgoingContentIsNotKept() {
        let pane = pane()
        let page = NSView()
        pane.show(page)
        page.isHidden = true
        let agent = Unpainted()
        pane.show(agent)
        #expect(page.superview == nil)
        #expect(agent.alphaValue == 1)
    }
}

extension PanePaintHoldTests {
    /// No-flicker audit: a page tab (App Store, History, Keyboard Shortcuts…)
    /// on a host whose document has not painted is transparent too, so the
    /// pane keeps what it showed until the page paints, as for an agent page.
    @Test func anUnpaintedPageTabKeepsTheOutgoingContent() throws {
        let pane = pane()
        let terminal = NSView()
        pane.show(terminal)
        let web = try #require(PageWebView(pooledHost: .settings))
        #expect(!web.hasPainted)
        let page = InternalPageView(key: "page-tab", page: .settings, content: web)
        pane.show(page)
        #expect(pane.content === page)
        #expect(terminal.superview === pane.contentHost, "the pane went empty before the page painted")
        #expect(page.alphaValue == 0)
    }
}

extension PanePaintHoldTests {
    /// Cursor review (#18437): a pooled host retargeted to another page has
    /// not painted the new document, though it painted the last one, so the
    /// pane still holds its outgoing content until the new page paints.
    @Test func aRetargetedPageTabKeepsTheOutgoingContent() throws {
        let pane = pane()
        let terminal = NSView()
        pane.show(terminal)
        let web = try #require(PageWebView(pooledHost: .settings))
        web.paintedUptime = 1 // the Settings document painted
        #expect(web.retarget(descriptor: .history, routes: []))
        #expect(!web.hasPainted, "a new document has not painted")
        let page = InternalPageView(key: "history-tab", page: .settings, content: web)
        pane.show(page)
        #expect(terminal.superview === pane.contentHost, "the pane went empty before the page painted")
        #expect(page.alphaValue == 0)
    }
}

extension PanePaintHoldTests {
    /// Cursor review (#18612): switching from one unpainted agent page to
    /// another keeps the content that was on screen, not the first page,
    /// which never showed.
    @Test func aSecondUnpaintedPageKeepsTheShownContent() {
        let pane = pane()
        let terminal = NSView()
        pane.show(terminal)
        let first = Unpainted()
        pane.show(first)
        let second = Unpainted()
        pane.show(second)
        #expect(pane.content === second)
        #expect(terminal.superview === pane.contentHost, "the pane went empty before the second page painted")
        #expect(first.superview == nil)
        #expect(first.alphaValue == 1)
        #expect(second.alphaValue == 0)

        second.paint()
        #expect(terminal.superview == nil)
        #expect(second.alphaValue == 1)
    }
}
