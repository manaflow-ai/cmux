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
/// shows nothing and takes no events; the pane sized it on every step (`layoutParked`, `retire`) so that showing it again
/// needs no layout at a new size. Chrome lays out no `display: none` box. Now a parked page does not lay out while it is
/// hidden; it lays out once at its pane's size when it shows.
///
/// Counted with probe views in the page (an `NSButton`, a SwiftUI hosting view, Liquid Glass and a plain view, the kinds
/// of view the docked Home has), across five steps of a window resize from its lower-left corner as the films drag.
/// `theSpareKindOfViewLaysOutOnlyWhenItsFrameChanges` asks the same of a view that keeps its frame: the New Tab spare's
/// views laid out 143 times per ON film in the films while their frame never changed.
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
        counts.reset()
        let parkedFrame = page.frame

        for _ in 1...5 { Self.resizeStep(window) }
        #expect(counts.total == 0, "the parked page laid out over 5 window resize steps: \(counts.calls) (its frame \(parkedFrame) -> \(page.frame))")

        // Shown again: at the size the pane shows it at now, laid out there.
        counts.reset()
        pane.show(page)
        Self.settle(pane)
        #expect(!page.isHidden, "the page did not show")
        let shows = (pane.parkedFrame(of: page) ?? pane.contentHost.bounds).size
        #expect(page.frame.size == shows, "shown again, the page is \(page.frame.size), not the \(shows) the pane shows it at")
        #expect((counts.calls["view"] ?? 0) >= 1, "shown again, the page did not lay out at its new size: \(counts.calls)")
    }

    @Test func theSpareKindOfViewLaysOutOnlyWhenItsFrameChanges() throws {
        let window = Self.window()
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = root
        // What the window shows: it follows the window.
        let shown = NSView(frame: root.bounds)
        shown.autoresizingMask = [.width, .height]
        root.addSubview(shown)
        // The New Tab spare's parking: in the window, shown, transparent and far outside the content, at a fixed size.
        let offscreen = LayoutCounts(), hidden = LayoutCounts()
        let parking = NSView(frame: NSRect(x: -100_000, y: -100_000, width: 700, height: 500))
        parking.alphaValue = 0
        parking.autoresizingMask = []
        parking.addSubview(Self.probes(offscreen, frame: parking.bounds))
        root.addSubview(parking)
        // A hidden view that keeps its frame (a parked page that no longer follows its pane).
        let parked = Self.probes(hidden, frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        parked.isHidden = true
        parked.autoresizingMask = []
        root.addSubview(parked)
        window.orderFrontRegardless()
        Self.settle(root)
        window.displayIfNeeded()
        offscreen.reset()
        hidden.reset()

        for _ in 1...5 { Self.resizeStep(window) }
        #expect(offscreen.total == 0, "the spare's kind of view laid out over 5 window resize steps with its frame unchanged: \(offscreen.calls)")
        #expect(hidden.total == 0, "a hidden view that keeps its frame laid out over 5 window resize steps: \(hidden.calls)")
    }
}
