import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs
import Testing

/// A lower split pane's strip is inside the content card, where a tab in the content's own colour would vanish, so it
/// kept a gray pill while the top row's selected tab was a folder into the content. Leo, 2026-11-12: "fixing up the
/// whole, like, polish of the two-tone mode". While the top row's tabs are folders (`CornerFlushChrome.markTopRow`), a
/// strip inside the card tones its own row, less its selected tab, so that tab is a folder into its pane too.
@MainActor @Suite(.serialized) struct TwoToneLowerStripTests {
    @Test func aTonedStripInsideTheCardRunsItsSelectedTabIntoTheContent() throws {
        // The flush corner pinned on (Debug Settings), so the test always asserts.
        // Compact density keeps the pill before any override is read (`CornerFlush.current`): pin Default's.
        let density = DesignSettings.shared.densityTokens
        DesignSettings.shared.densityTokens = DensityPreset.cozy.tokens
        defer { DesignSettings.shared.densityTokens = density }
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let flush = store.set(CornerFlush.tunable.key, .choice(CornerFlush.goo.rawValue))
        defer { _ = store.set(CornerFlush.tunable.key, flush) }
        try #require(CornerFlush.current.isOn && DesignSettings.shared.tabBarPosition != .bottom,
                     "the pinned flush corner is off (compact density, or tabs at the bottom)")
        let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("tab1")))
        strip.dragsWindowFromEmptySpace = false
        window.contentView = strip
        func layout() {
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            strip.needsLayout = true
            strip.layoutSubtreeIfNeeded()
        }
        layout()
        strip.setRunsIntoCard(false)
        layout()
        let selected = try #require(strip.cells[TabID("tab1")])
        #expect(!selected.runsIntoCard, "an untoned strip inside the card keeps the pill")
        #expect(strip.inCardTone?.shade.path == nil)

        strip.setTonedInCard(true)
        layout()
        #expect(selected.runsIntoCard, "a toned strip's selected tab is a folder into its pane")
        let tone = try #require(strip.inCardTone)
        let shade = try #require(tone.shade.path)
        let folder = try #require(strip.selectedFolderPath(in: tone.shade)).boundingBoxOfPath
        #expect(!shade.contains(CGPoint(x: folder.midX, y: folder.midY)), "the folder is cut out of the row's shade")
        #expect(shade.contains(CGPoint(x: strip.bounds.maxX - 2, y: strip.bounds.midY)), "the rest of the row is toned")

        strip.setTonedInCard(false)
        layout()
        #expect(!selected.runsIntoCard)
        #expect(tone.shade.path == nil)
    }
}
