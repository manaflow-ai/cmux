#if DEBUG
import AppKit
@testable import CmuxNextCompat
import CmuxNextDesign
import Foundation
import Testing

/// Debug menu > Main-Thread Blocking (N): the count follows the detector when the Debug menu opens,
/// the submenu lists each site, then the caller's Reset Counts row (the registry's action item).
@MainActor
@Suite
struct BlockingCallsMenuTests {
    @Test func theItemShowsTheSitesWhenTheMenusOpen() async throws {
        let table = BlockingViolationTable(mode: .record)
        let resetRow = NSMenuItem(title: "debug.blockingCalls.reset", action: nil, keyEquivalent: "")
        let menu = BlockingCallsMenu(detector: BlockingDetector(table: table), resetItem: { resetRow })
        let debugMenu = NSMenu(title: "Debug")
        menu.attach(to: debugMenu)
        let item = try #require(debugMenu.items.last)
        let before = item.title

        await BlockingViolationTable.$scoped.withValue(table) {
            _ = FileManager.checked.fileExists(atPath: "/")
        }
        await table.flush()
        menu.menuNeedsUpdate(debugMenu)
        let submenu = try #require(item.submenu)
        menu.menuNeedsUpdate(submenu)

        #expect(item.title != before)
        #expect(item.title.contains("1"))
        #expect(submenu.items.first?.title.hasPrefix("file-io  CmuxNextDesignTests/BlockingCallsMenuTests.swift:") == true)
        let reset = try #require(submenu.items.last)
        #expect(reset === resetRow)
        #expect(reset.title != "debug.blockingCalls.reset")
    }

    /// Debug records a new site instead of stopping: the item carries a badge with the
    /// number of sites nobody looked at, from the Debug menu's open until the submenu opens.
    @Test func aNewSiteBadgesTheItemUntilTheSubmenuOpens() async throws {
        let table = BlockingViolationTable(mode: .record)
        let menu = BlockingCallsMenu(detector: BlockingDetector(table: table), resetItem: { nil })
        let debugMenu = NSMenu(title: "Debug")
        menu.attach(to: debugMenu)
        let item = try #require(debugMenu.items.last)
        let submenu = try #require(item.submenu)
        menu.menuNeedsUpdate(debugMenu)
        #expect(item.badge == nil)

        await BlockingViolationTable.$scoped.withValue(table) {
            Self.blockAtOneSite()
            _ = FileManager.checked.fileExists(atPath: "/tmp")
        }
        await table.flush()
        menu.menuNeedsUpdate(debugMenu)
        #expect(item.badge?.itemCount == 2)

        menu.menuNeedsUpdate(submenu)
        #expect(item.badge == nil)
        // A site that blocks again is not new.
        await BlockingViolationTable.$scoped.withValue(table) { Self.blockAtOneSite() }
        await table.flush()
        menu.menuNeedsUpdate(debugMenu)
        #expect(item.badge == nil)
        #expect(table.sites.count == 2)
    }

    /// One seam call on the main thread, always at the same call site.
    private static func blockAtOneSite() {
        _ = FileManager.checked.fileExists(atPath: "/")
    }
}
#endif
