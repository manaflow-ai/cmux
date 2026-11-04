import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import SwiftUI
import Testing

/// FRAME OWNER REFACTOR S7b. In a window's live resize every page parked in a pane laid its tree out on every step:
/// in the S7 films (ab-s7p5-22, cmux22) the docked Home, hidden in its pane while a workspace shows, laid out its views
/// 141 times in an ON film of 72 steps and 191 in an OFF film of 142 (`debug.layers` `top_instances`). A parked page
/// shows nothing and takes no events; the pane sized it on every step (`layoutParked`) so that showing it again needed
/// no layout at a new size. Chrome lays out no `display: none` box. Now a parked page keeps its frame while it is hidden
/// and is sized once when it shows: its AppKit views lay nothing out per step.
///
/// Counted with probe views in the page (an `NSButton`, Liquid Glass and a plain view, kinds of view the docked Home has),
/// across five steps of a window resize from its lower-left corner as the films drag. A SwiftUI hosting view in the page
/// is not counted: in the window it lays out on each step even hidden at a fixed frame (5 calls over 5 steps at
/// 3dfa3a9a5a9; the New Tab spare's, whose frame never changes, 143 per ON film). Only a view out of the window stops
/// that: the docked Home's Messages view leaves the window while it is parked (HomeDockParkedMessagesTests).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct ParkedPageWindowResizeLayoutTests {
    /// Layout calls per probe kind.
    @MainActor final class LayoutCounts {
        private(set) var calls: [String: Int] = [:]
        func note(_ kind: String) { calls[kind, default: 0] += 1 }
        func reset() { calls = [:] }
        var total: Int { calls.values.reduce(0, +) }
    }

    final class ProbeView: NSView {
        var counts: LayoutCounts?
        override func layout() {
            super.layout()
            counts?.note("view")
        }
    }

    final class ProbeButton: NSButton {
        var counts: LayoutCounts?
        override func layout() {
            super.layout()
            counts?.note("button")
        }
    }

    final class ProbeHosting: NSHostingView<Text> {
        var counts: LayoutCounts?
        required init(rootView: Text) { super.init(rootView: rootView) }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            counts?.note("hosting")
        }
    }

    @available(macOS 26.0, *)
    final class ProbeGlass: NSGlassEffectView {
        var counts: LayoutCounts?
        override func layout() {
            super.layout()
            counts?.note("glass")
        }
    }

    /// A terminal or browser: parked in place, shown under the strip.
    final class Other: NSView, PaneParkableContent {}

    /// A page body with one probe of each kind, laid out by autoresizing as the page's size changes.
    static func probes(_ counts: LayoutCounts, frame: NSRect) -> NSView {
        let body = ProbeView(frame: frame)
        body.counts = counts
        let button = ProbeButton(title: "Send", target: nil, action: nil)
        button.counts = counts
        button.frame = NSRect(x: 20, y: 20, width: 100, height: 28)
        button.autoresizingMask = [.maxXMargin, .maxYMargin]
        let hosting = ProbeHosting(rootView: Text("Home"))
        hosting.counts = counts
        hosting.frame = NSRect(x: 20, y: 60, width: max(0, frame.width - 40), height: 40)
        hosting.autoresizingMask = [.width, .maxYMargin]
        body.addSubview(button)
        body.addSubview(hosting)
        if #available(macOS 26.0, *) {
            let glass = ProbeGlass(frame: NSRect(x: 20, y: 110, width: max(0, frame.width - 40), height: 60))
            glass.counts = counts
            glass.cornerRadius = 12
            glass.contentView = NSTextField(labelWithString: "Search")
            glass.autoresizingMask = [.width, .maxYMargin]
            body.addSubview(glass)
        }
        return body
    }

    static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// One step of a live resize from the lower-left corner, smaller: the left edge moves right and the bottom up.
    static func resizeStep(_ window: NSWindow) {
        var frame = window.frame
        frame.origin.x += 20
        frame.size.width -= 20
        frame.origin.y += 12
        frame.size.height -= 12
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    static func settle(_ view: NSView) {
        for _ in 0..<3 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    @Test func aParkedPageDoesNoLayoutWhileTheWindowResizesAndLaysOutOnceAtItsPanesSizeWhenItShows() throws {
        let window = Self.window()
        defer { window.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("home"), title: "Home"),
                                                                     TabItem(id: TabID("term"), title: "Terminal")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()
        let counts = LayoutCounts()
        let page = InternalPageView(key: "local-page:home:s7b", page: InternalPageID(rawValue: "home"),
                                    content: Self.probes(counts, frame: NSRect(x: 0, y: 0, width: 900, height: 560)))
        pane.show(page)
        Self.settle(pane)
        pane.show(Other())
        Self.settle(pane)
        try #require(page.isHidden && page.window === window, "SETUP: the page is not parked in the window")
        let parkedFrame = page.frame

        // Per step: the first may still lay out what the park itself left dirty (a view hidden mid-pass); every step after
        // it is the resize alone.
        var perStep: [[String: Int]] = []
        for _ in 1...6 {
            counts.reset()
            Self.resizeStep(window)
            perStep.append(counts.calls.filter { $0.key != "hosting" })
        }
        #expect(page.frame == parkedFrame, "the parked page followed the window: \(parkedFrame) -> \(page.frame)")
        let laidOutAfterFirst = perStep.dropFirst().contains { !$0.isEmpty }
        #expect(!laidOutAfterFirst, "the parked page's AppKit views laid out on resize steps: \(perStep)")

        // Shown again: at the size the pane shows it at now, laid out there.
        counts.reset()
        pane.show(page)
        Self.settle(pane)
        #expect(!page.isHidden, "the page did not show")
        let shows = (pane.parkedFrame(of: page) ?? pane.contentHost.bounds).size
        #expect(page.frame.size == shows, "shown again, the page is \(page.frame.size), not the \(shows) the pane shows it at")
        #expect((counts.calls["view"] ?? 0) >= 1, "shown again, the page did not lay out at its new size: \(counts.calls)")
    }
}
