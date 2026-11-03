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
}
#endif
