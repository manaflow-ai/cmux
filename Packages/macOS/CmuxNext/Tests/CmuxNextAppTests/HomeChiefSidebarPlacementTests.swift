import AppKit
import Foundation
import Testing
@testable import CmuxNextApp

/// The Chief Settings sidebar shows and writes the engine of the brain that
/// answers this Chief (2026-10-08: a Chief placed on cmux-lawrence showed
/// and wrote this Mac's `engine.json`, so the sidebar said codex while the
/// server ran claude-sr). A Chief whose brain runs on a paired server says
/// so and shows no local harness, model or traces.
@MainActor @Suite struct HomeChiefSidebarPlacementTests {
    static func views(_ root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(views)
    }

    static func visibleTexts(_ root: NSView) -> [String] {
        views(root).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
    }

    static func home() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chief-sidebar-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aChiefOnThisMacShowsThisMacsEngine() {
        let home = Self.home()
        let sidebar = HomeChiefSidebar(muxHome: home)
        let popups = Self.views(sidebar).compactMap { $0 as? NSPopUpButton }
        #expect(popups.count == 3)
        #expect(popups.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        #expect(Self.visibleTexts(sidebar).contains { $0.contains(home.path) })
    }

    @Test func aChiefOnAPairedServerShowsWhereItRunsAndNoLocalEngine() {
        let home = Self.home()
        let sidebar = HomeChiefSidebar(muxHome: home)
        sidebar.setRunsElsewhere(true)
        let popups = Self.views(sidebar).compactMap { $0 as? NSPopUpButton }
        #expect(popups.count == 3)
        #expect(popups.allSatisfy { $0.isHiddenOrHasHiddenAncestor }, "no picker writes this Mac's engine.json")
        let texts = Self.visibleTexts(sidebar)
        #expect(texts.contains(HomeEngineStrings.runsElsewhere), "\(texts)")
        #expect(!texts.contains { $0.contains(home.path) }, "\(texts)")
        let buttons = Self.views(sidebar).compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) }
        #expect(buttons.allSatisfy { $0.isHiddenOrHasHiddenAncestor }, "no local traces or memory")
        // Back on this Mac (the conversation moved): the engine shows again.
        sidebar.setRunsElsewhere(false)
        #expect(Self.views(sidebar).compactMap { $0 as? NSPopUpButton }.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
    }
}
