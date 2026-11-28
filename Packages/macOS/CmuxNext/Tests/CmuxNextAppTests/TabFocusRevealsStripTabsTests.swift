import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextMacScreen
import CmuxNextTestSupport
import Foundation
import Testing

/// `tab.focus` on a session-local strip tab (a Mac Screen tab the daemon does not hold, `local-page:mac-screen:…`)
/// selects it, as the strip click does. Signed probe run 46125220823 (cmuxterm-hq, 2026-11-28 08:18Z) refused with
/// "No tab matches local-page:mac-screen:…" because the action only searched the daemon store.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct TabFocusRevealsStripTabsTests {
    @Test func tabFocusSelectsAnAppOnlyMacScreenTab() async throws {
        try await AppHarnessWindows.withApp { services, _ in
            let model = try MoveToNewWindowTests.firstPane(services)
            // Outside #require: its expansion re-chains `?.` onto the lazy compactMap result and fails to compile.
            let found = services.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.pane === model } }.first
            let pane = try #require(found)
            let record = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?device=0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff")!))
            let key = services.macScreenTabs.open(record, in: pane, focus: false, byPerson: false)
            try await PinnedPageTests.until({ pane.stripModel.tab(StripTabID(key)) != nil })
            #expect(pane.stripModel.selectedID?.rawValue != key, "opened unfocused")
            #expect(services.registry.perform("tab.focus", invocation: MoveToNewWindowTests.on(.tab, key)))
            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == key })
        }
    }
}
