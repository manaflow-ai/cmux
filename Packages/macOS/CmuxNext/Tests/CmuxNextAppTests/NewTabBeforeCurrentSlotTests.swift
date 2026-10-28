@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Testing

/// `tabs.newTabPosition` "beforeCurrent" (user 2026-10-27: "new tabs to be created on the left side
/// instead of right side"): Cmd-T and the strip's + put the new tab right before (to the left of) the
/// current tab, never among the pinned tabs and never inside the current tab's group. New Tab Before
/// Current Tab does it whatever the setting says. The default stays right after the current tab.
@MainActor struct NewTabBeforeCurrentSlotTests {
    /// A pinned tab, then `t2`, `t3`, `t4`.
    private static func tabs() -> [TabModel] {
        [TabModel(TabSnapshot(surface: SurfaceID(rawValue: 1), title: "pinned", pinned: true))]
            + (2...4).map { TabModel(TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "t\($0)")) }
    }

    private static func index(_ target: NewTabSlot.Target?, in others: [TabModel]) -> Int {
        target.flatMap { NewTabSlot.slot(for: $0, in: others) } ?? others.count
    }

    @Test func cmdTWithTheSettingLandsRightBeforeTheCurrentTab() {
        let others = Self.tabs()
        let target = NewTabSlot.target(current: others[2], pane: others, explicit: nil, user: true, setting: .beforeCurrent)
        #expect(Self.index(target, in: others) == 2, "between t2 and t3, t3 selected")
    }

    @Test func theFirstUnpinnedTabGetsTheNewTabRightAfterThePinnedOnes() {
        let others = Self.tabs()
        let target = NewTabSlot.target(current: others[1], pane: others, explicit: nil, user: true, setting: .beforeCurrent)
        #expect(Self.index(target, in: others) == 1)
        let onPinned = NewTabSlot.target(current: others[0], pane: others, explicit: nil, user: true, setting: .beforeCurrent)
        #expect(Self.index(onPinned, in: others) == 1, "never among the pinned tabs")
    }

    @Test func theExplicitActionIgnoresTheSetting() {
        let others = Self.tabs()
        for setting in NewTabPosition.allCases {
            let target = NewTabSlot.target(current: others[3], pane: others, explicit: .beforeCurrent, user: true, setting: setting)
            #expect(Self.index(target, in: others) == 3)
        }
    }

    @Test func theDefaultIsStillAfterTheCurrentTab() {
        let others = Self.tabs()
        let target = NewTabSlot.target(current: others[2], pane: others, explicit: nil, user: true, setting: nil)
        #expect(Self.index(target, in: others) == 3)
    }
}
