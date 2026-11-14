import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
@testable import CmuxNextApp
import CmuxNextTabs
import Foundation
import Testing

/// The Home dock as a pinned column (`pinned-dock-v1`; Lawrence 2026-10-18: "I should not be able to
/// close Home inside the Home thing ... should not be able to create more tabs in the Home thing unless
/// I explicitly enable it"). The daemon refuses; the app shows no control that would ask.
@MainActor
struct PinnedHomeDockTests {
    @Test func theDaemonsPinnedFlagsDecodeAndDefaultOff() throws {
        let pinned = try JSONDecoder().decode(DockSnapshot.self, from: Data(#"""
        {"edge":"left","mode":"docked","role":"agent_chat","pinned":true,"allow_tabs":true}
        """#.utf8))
        #expect(pinned.isPinned && pinned.allowsTabs)
        let plain = try JSONDecoder().decode(DockSnapshot.self, from: Data(#"{"edge":"left","mode":"docked"}"#.utf8))
        #expect(!plain.isPinned && !plain.allowsTabs)
        let layout = LayoutMapping.dock(pinned)
        #expect(layout.isPinned && layout.allowsTabs && layout.takesTabs)
        #expect(!LayoutMapping.dock(DockSnapshot(edge: .left, mode: .docked, isPinned: true)).takesTabs)
    }

    /// Home's tab shows no x, even selected and hovered, where an ordinary tab shows one.
    @Test func aTabThatCannotCloseShowsNoCloseButton() {
        let closable = TabChromeVisibility.resolve(width: 220, isPinned: false, isSelected: true, isHovered: true, style: .chrome)
        let home = TabChromeVisibility.resolve(width: 220, isPinned: false, isSelected: true, isHovered: true,
                                               isClosable: false, style: .chrome)
        #expect(closable.showsClose)
        #expect(!home.showsClose)
        #expect(home.showsTitle)
        let path = TabChromeVisibility.path(widths: [120, 180, 220], from: home, isPinned: false, isSelected: true,
                                            isHovered: true, isClosable: false, style: .chrome)
        #expect(path.allSatisfy { !$0.showsClose })
    }

    /// Cmd-W on Home's tab keeps it (another tab is selected when there is one), though Cmd-W closes
    /// pinned tabs.
    @Test func cmdWKeepsATabThatCannotClose() {
        var home = TabItem(id: "home", title: "Home")
        home.isClosable = false
        let alone = TabStripModel(tabs: [home], selectedID: "home")
        #expect(alone.keyboardClose("home") == .ignore) // kept, silently (home-chief-pane.md)
        let two = TabStripModel(tabs: [home, TabItem(id: "t", title: "t")], selectedID: "home")
        #expect(two.keyboardClose("home") == .select("t"))
        #expect(two.keyboardClose("t") == .close)
    }

    @Test func refusedCloseOfHomeSaysHomeStays() {
        #expect(RefusedCloseNotice.reason(codes: ["dock-column-pinned"]) == RefusalStrings.homeTabStays)
        #expect(RefusedCloseNotice.reason(codes: ["dock-column-permanent"]) == RefusalStrings.columnStaysDocked)
    }
}
