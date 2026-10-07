import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// DOGFOOD-CALL L4 (Leo: "performant and smooth above all"): switching tabs
/// must not show a frame that mixes two tabs. The strip's highlight and the
/// pane's content change in the same pass, so they commit in one Core
/// Animation transaction: no frame shows the new tab highlighted over the
/// old tab's content, or the old highlight over the new content.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct TabSwitchFrameTests {
    /// What one display frame would show of `pane`: the strip's drawn
    /// selection and the content the pane hosts.
    private struct Frame: Equatable {
        var stripModel: String?
        var stripDrawn: String?
        var content: String?
        var hostedView: ObjectIdentifier?
    }

    private func frame(_ pane: PaneController) -> Frame {
        Frame(stripModel: pane.stripModel.selectedID?.rawValue, stripDrawn: pane.view.stripView.lastSelectedID?.rawValue,
              content: pane.currentTabKey, hostedView: pane.view.hostsContent ? pane.view.content.map(ObjectIdentifier.init) : nil)
    }

    private func expected(_ pane: PaneController, _ tab: StripTabID) -> Frame {
        Frame(stripModel: tab.rawValue, stripDrawn: tab.rawValue, content: tab.rawValue,
              hostedView: pane.existingContent(for: tab.rawValue).map { ObjectIdentifier($0.view) })
    }

    @Test func aUserTabSwitchChangesTheStripAndTheContentInOnePass() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let pane = try #require(harness.pane)
        let first = try #require(pane.stripModel.selectedID)
        let other = try #require(pane.stripModel.orderedTabs.map(\.id).first { $0 != first })
        // Show both tabs once, so both contents are alive (the common case: tabs the user already visited).
        for tab in [other, first] {
            pane.select(tab, source: .mouse)
            try await ViewChangePermissionTests.waitUntil("tab \(tab.rawValue) shown") {
                pane.currentTabKey == tab.rawValue && pane.view.hostsContent
            }
        }
        #expect(pane.selectedContentIsAlive)
        #expect(pane.existingContent(for: other.rawValue) != nil, "the visited tab keeps its content")
        let before = frame(pane)
        #expect(before == expected(pane, first))

        // The switch. No await between the user's selection and the check:
        // anything the next frame would show must already be in place.
        pane.select(other, source: .mouse)
        let after = frame(pane)
        #expect(after == expected(pane, other), "strip and content must change together (before: \(before), after: \(after))")

        // And back, the same way.
        pane.select(first, source: .mouse)
        #expect(frame(pane) == expected(pane, first))
    }

    /// A tab never shown before has no surface yet; one is made on the next
    /// frame. In the selection's own pass the old tab's content leaves and
    /// the pane shows its empty background under the new highlight, never
    /// the old tab under the new highlight.
    @Test func aFirstVisitShowsAnEmptyPaneUnderTheNewHighlightThenItsContent() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let pane = try #require(harness.pane)
        let first = try #require(pane.stripModel.selectedID)
        let known = Set(pane.stripModel.orderedTabs.map(\.id))
        // Made in the background (an automation run): listed, never shown.
        try await ViewChangePermissionTests.run(harness, "newSurface", origin: "cli")
        try await ViewChangePermissionTests.waitUntil("new tab listed") { pane.stripModel.orderedTabs.count == known.count + 1 }
        let fresh = try #require(pane.stripModel.orderedTabs.map(\.id).first { !known.contains($0) })
        #expect(pane.existingContent(for: fresh.rawValue) == nil, "a first visit has no content yet")
        #expect(frame(pane) == expected(pane, first))
        let oldView = try #require(pane.view.content)

        pane.select(fresh, source: .mouse)
        let placeholder = frame(pane)
        #expect(placeholder == Frame(stripModel: fresh.rawValue, stripDrawn: fresh.rawValue, content: nil, hostedView: nil),
                "empty pane under the new highlight, not the old tab (got \(placeholder))")
        #expect(oldView.superview !== pane.view.contentHost)

        try await ViewChangePermissionTests.waitUntil("first visit shown") { pane.currentTabKey == fresh.rawValue && pane.view.hostsContent }
        #expect(frame(pane) == expected(pane, fresh))
    }

    /// The default bar order (strip above a browser's toolbar): the strip
    /// and the content area keep their frames when the pane switches between
    /// a terminal-like view and a browser. A frame that moves here is a
    /// visible jump of every tab in the strip.
    @Test func theStripAndContentFramesStayWhenATerminalAndABrowserSwap() {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "zsh"), TabItem(id: TabID("b0"), title: "cmux")],
                                  selectedID: TabID("t0"))
        let pane = PaneContentView(stripModel: model)
        pane.barPosition = .top
        pane.barOrder = .aboveToolbar
        // Never ordered front: the window only gives the views one tree.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = pane
        let terminal = NSView()
        let browser = BrowserChromeView(tab: MockBrowserEngine().makeMockTab(BrowserTabConfiguration()))
        pane.show(terminal)
        pane.layoutSubtreeIfNeeded()
        let strip = pane.stripView.frame, host = pane.contentHost.frame
        for view in [browser, terminal, browser, terminal] as [NSView] {
            pane.show(view)
            pane.layoutSubtreeIfNeeded()
            #expect(pane.stripView.frame == strip)
            #expect(pane.contentHost.frame == host)
            #expect(view.frame == pane.contentHost.bounds)
        }
        _ = window
    }
}
