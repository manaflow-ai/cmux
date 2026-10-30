import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing
import CmuxNextTestSupport

/// Chrome-parity p03-rendering-065 (MQ-damage-owners, CmuxNextPalette): the palette renders its
/// search bar, footer, rows, Actions menu and shortcut recorder on every model change (each typed
/// character, each hover), and a view asks for a layout or a paint only when a value it shows
/// changed. Chromium invalidates paint for the properties that changed, never for a re-render of
/// the same state (third_party/blink/renderer/core/paint/paint_invalidator.cc;
/// cc/layers/layer.cc `SetNeedsDisplayRect` for changed contents only).
@MainActor @Suite(.serialized, .renderHooks)
struct PaletteInvalidationTests {
    /// `view` in a window, laid out at `size`, with no layout or paint pending.
    private func hosted(_ view: NSView, size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 800, height: 400)),
                              styleMask: .borderless, backing: .buffered, defer: false)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(origin: .zero, size: size)
        settle(view)
        return window
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.needsDisplay = false
    }

    private static func item(_ id: String, _ title: String, subtitle: String? = nil, keycaps: [String]? = nil) -> PaletteItem {
        PaletteItem(id: id, title: title, subtitle: subtitle, keycaps: keycaps,
                    primary: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}))
    }

    private func updateBar(_ bar: PaletteSearchBar, query: String, hint: String? = nil, chips: [PaletteScopeChip] = []) {
        bar.update(query: query, placeholder: "Search", chips: chips, rootTitle: "Commands", style: .token,
                   keywordHint: hint, isLoading: false)
    }

    /// One typed character as the palette sees it: the field shows it, then the model's render
    /// passes the same query back to the bar.
    private func type(_ query: String, into bar: PaletteSearchBar) {
        bar.field.stringValue = query
        settle(bar)
        updateBar(bar, query: query)
    }

    /// A typed character changes the field's text and moves nothing: the bar lays out only for a new
    /// scope or keyword hint.
    @Test func typingLaysOutNoSearchBar() {
        let bar = PaletteSearchBar(frame: .zero)
        let window = hosted(bar, size: NSSize(width: 640, height: 52))
        defer { window.close() }
        updateBar(bar, query: "")
        settle(bar)
        for query in ["t", "ta", "tab"] {
            type(query, into: bar)
            #expect(!bar.needsLayout, "typing \(query) laid the bar out")
        }
        updateBar(bar, query: "tab", hint: "Tabs")
        #expect(bar.needsLayout, "a keyword hint takes room")
        bar.field.stringValue = "tabs"
        settle(bar)
        updateBar(bar, query: "tabs", hint: "Tabs")
        #expect(!bar.needsLayout, "the same hint laid the bar out")
        updateBar(bar, query: "", chips: [PaletteScopeChip(levelIndex: 1, scope: "tabs", title: "Tabs", symbol: "square.on.square")])
        #expect(bar.needsLayout, "a scope chip moves the field")
    }

    /// The footer shows the same page and primary action for most renders: it lays out only for new text.
    @Test func anEqualFooterUpdateAsksForNothing() {
        let footer = PaletteFooterView(frame: .zero)
        let window = hosted(footer, size: NSSize(width: 640, height: 36))
        defer { window.close() }
        func update(primary: String?, enabled: Bool = true) {
            footer.update(pageTitle: "Commands", pageSymbol: "command", primaryTitle: primary, actionsEnabled: enabled)
        }
        update(primary: "Open")
        settle(footer)
        update(primary: "Open")
        #expect(!footer.needsLayout)
        update(primary: "Open", enabled: false)
        #expect(!footer.needsLayout, "dimming the Actions hint moves nothing")
        update(primary: "Run")
        #expect(footer.needsLayout, "new primary text takes a new width")
    }

    /// The list configures every visible row on each result change: a row with the same text and
    /// matches lays out nothing, a new match or title lays it out.
    @Test func anEqualRowConfigureLaysOutNothing() {
        let cell = PaletteRowCell(frame: .zero)
        let window = hosted(cell, size: NSSize(width: 600, height: 28))
        defer { window.close() }
        let item = Self.item("a", "Open Tab", subtitle: "Tabs", keycaps: ["⌘", "T"])
        cell.configure(PaletteRow(item: item, highlights: [0], score: 1), isSelected: false)
        settle(cell)
        cell.configure(PaletteRow(item: item, highlights: [0], score: 2), isSelected: false)
        #expect(!cell.needsLayout, "the same row laid out again")
        cell.configure(PaletteRow(item: item, highlights: [0], score: 2), isSelected: true)
        #expect(!cell.needsLayout, "a selection tints the icon only")
        cell.configure(PaletteRow(item: item, highlights: [0, 1], score: 2), isSelected: true)
        #expect(cell.needsLayout, "a new match changes the title's width")
    }

    /// An open Actions menu is rendered on every model change: the same state keeps its rows.
    @Test func anEqualActionsMenuUpdateKeepsItsRows() {
        let menu = PaletteActionsMenuView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let window = hosted(menu, size: NSSize(width: 300, height: 400))
        defer { window.close() }
        let commands = (0..<3).map { PaletteCommand(id: "c\($0)", title: "Command \($0)", symbol: "return", effect: .perform {}) }
        let state = PaletteActionsMenuState(itemID: "item", itemTitle: "Item", commands: commands)
        menu.update(state, alternateID: nil)
        settle(menu)
        let rows = Self.menuRows(in: menu)
        menu.update(state, alternateID: nil)
        #expect(!menu.needsLayout)
        #expect(Self.menuRows(in: menu).map(ObjectIdentifier.init) == rows.map(ObjectIdentifier.init), "the same state rebuilt the rows")
        var filtered = state
        filtered.filter = "1"
        menu.update(filtered, alternateID: nil)
        #expect(menu.needsLayout, "a new filter shows other rows")
    }

    /// RenderStats' count of the search bar's `layout()` calls from the renders of three typed
    /// characters: 0. Before this change each render laid the bar out once. RenderStats counts
    /// `layout()` through the layout pass guard, wired as the app wires it (`AppControl`).
    @Test func renderStatsCountsNoTypingLayouts() async {
        let layoutGuard = LayoutPassGuard.shared
        layoutGuard.install() // hooks `-[NSView layout]`; idempotent
        let stats = RenderStats(layoutGuard: layoutGuard)
        guard stats.arm() else { return } // a build without the hooks
        let counting = await stats.ready()
        #expect(counting, "RenderStats did not start counting")
        if counting {
            let bar = PaletteSearchBar(frame: .zero)
            let window = hosted(bar, size: NSSize(width: 640, height: 52))
            updateBar(bar, query: "")
            settle(bar)
            func layouts() -> Int {
                stats.owners().first { $0.key == RenderStats.classKey(PaletteSearchBar.self) }?.totals[.layouts] ?? 0
            }
            // A layout the bar must do is counted, so the 0 below is the renders' own.
            let forced = layouts()
            bar.needsLayout = true
            bar.layoutSubtreeIfNeeded()
            #expect(layouts() == forced + 1, "RenderStats did not count the search bar's layout")
            var rendered = 0
            for query in ["t", "ta", "tab"] {
                bar.field.stringValue = query
                settle(bar)
                let before = layouts()
                updateBar(bar, query: query)
                settle(bar)
                rendered += layouts() - before
            }
            #expect(rendered == 0, "the renders of typed characters laid the search bar out \(rendered) times")
            window.close()
        }
        stats.disarm()
        _ = await stats.ready()
    }

    private static func menuRows(in view: NSView) -> [PaletteMenuRow] {
        view.subviews.flatMap { subview -> [PaletteMenuRow] in
            if let row = subview as? PaletteMenuRow { return [row] }
            return menuRows(in: subview)
        }
    }
}
