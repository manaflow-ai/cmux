import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Selecting a tab never moves or resizes any tab (Lawrence 2026-10-19, "changing tab changes tab
/// width, which is bad"). Tab geometry is a function of the pane's tabs and width only: tabs coming
/// and going, a rename or a pane resize may change it, a selection never does.
///
/// The repro was a pane whose "…" (`PaneToolbar`) showed only for some selected tabs (none for a
/// window's own page tab or a chat): the strip gave the "…" its width while it showed, so every tab
/// shrank and grew as the selection moved. The second case was Chrome's crowded strip, where the
/// selected tab kept a larger minimum than the others.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabSelectionKeepsTabWidthsTests {
    private struct Geometry: Equatable, CustomStringConvertible {
        let strip: NSRect
        let slots: [String]
        var description: String { "strip \(strip), slots \(slots)" }
    }

    private static func geometry(_ strip: TabStripView, in pane: NSView? = nil) -> Geometry {
        Geometry(strip: pane == nil ? .zero : strip.frame,
                 slots: strip.result.slots.map { "\($0.id.rawValue)@\($0.x)+\($0.width)" })
    }

    /// A pane with store tabs (they offer "…") and local page tabs (they do not): every selection
    /// lays the strip out the same.
    @Test func selectingATabThatOffersNoMoreMenuKeepsEveryTabInPlace() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let ids = (0..<11).map { $0 % 3 == 2 ? "\(LocalPageTab.prefix)page\($0)" : "tab\($0)" }
        let model = TabStripModel(tabs: ids.map { TabItem(id: TabID($0), title: "cmux-prompt-commits \($0)") }, selectedID: TabID(ids[0]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
        pane.frame = NSRect(x: 0, y: 0, width: 1280, height: 300)
        window.contentView = pane
        let toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        pane.toolbar = toolbar

        var seen: [String: Geometry] = [:]
        for id in ids {
            model.selectedID = TabID(id)
            // What `PaneToolbar.state` reads for this selection: a local page tab has no "…".
            let local = id.hasPrefix(LocalPageTab.prefix)
            toolbar.update(target: local ? nil : id, kind: local ? nil : .terminal, paneKinds: [.terminal])
            pane.stripView.syncFromModel()
            pane.layoutSubtreeIfNeeded()
            pane.stripView.layoutSubtreeIfNeeded()
            seen[id] = Self.geometry(pane.stripView, in: pane)
        }
        let first = try #require(seen[ids[0]])
        for id in ids {
            #expect(seen[id] == first, "selecting \(id) laid the strip out as \(String(describing: seen[id])), not \(first)")
        }
    }

    /// A strip too narrow for every tab at its width: all tabs share the same width whichever is
    /// selected (no larger selected minimum that pushes the others).
    @Test func selectingATabInACrowdedStripKeepsEveryTabInPlace() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let ids = (0..<30).map { "tab\($0)" }
        let model = TabStripModel(tabs: ids.map { TabItem(id: TabID($0), title: "Tab \($0)") }, selectedID: TabID(ids[0]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        // 30 tabs in 1200 pt: 40 each, under the selected minimum and over the inactive one.
        strip.frame = NSRect(x: 0, y: 0, width: 1200, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        let first = Self.geometry(strip)
        // Even shares: whole points, the leftover points on the leading tabs (`TabLayoutEngine.distribute`).
        let widths = strip.result.slots.map(\.width)
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1, "\(Set(widths))")
        #expect((widths.min() ?? 0) < strip.metrics.minActiveTabWidth, "the strip is not crowded: \(Set(widths))")
        for id in ids {
            model.selectedID = TabID(id)
            strip.syncFromModel()
            strip.layoutSubtreeIfNeeded()
            #expect(Self.geometry(strip) == first, "selecting \(id) moved tabs")
        }
    }
}
