@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Testing

/// Where Cmd-T, the strip's +, and New Tab After Current Tab / at Start / at End put the new tab
/// (Lawrence 2026-10-20): right after the current tab by default, "end" and "start" by setting,
/// and the three palette actions whatever the setting says. Scripts' `tab new` keeps appending.
@MainActor struct NewTabPositionSlotTests {
    /// A pinned tab, then `a`, `b`, `c`; `b` is selected.
    private static func tabs() -> [TabModel] {
        [TabModel(TabSnapshot(surface: SurfaceID(rawValue: 1), title: "pinned", pinned: true))]
            + (2...4).map { TabModel(TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "t\($0)")) }
    }

    /// The final index the new tab lands at among `others` for `target` (nil: appended).
    private static func index(_ target: NewTabSlot.Target?, in others: [TabModel]) -> Int {
        target.flatMap { NewTabSlot.slot(for: $0, in: others) } ?? others.count
    }

    @Test func cmdTByDefaultLandsRightAfterTheCurrentTab() {
        let others = Self.tabs(), current = others[2]
        let target = NewTabSlot.target(current: current, pane: others, explicit: nil, user: true, setting: nil)
        #expect(Self.index(target, in: others) == 3)
    }

    @Test(arguments: [(NewTabPosition.afterCurrent, 3), (.end, 4), (.start, 1)])
    func cmdTFollowsTheSetting(position: NewTabPosition, expected: Int) {
        let others = Self.tabs(), current = others[2]
        let target = NewTabSlot.target(current: current, pane: others, explicit: nil, user: true, setting: position)
        #expect(Self.index(target, in: others) == expected)
    }

    /// New Tab After Current Tab, at Start and at End ignore the setting, for a person and a script.
    @Test(arguments: [(NewTabPosition.afterCurrent, 3), (.end, 4), (.start, 1)])
    func theExplicitActionsIgnoreTheSetting(position: NewTabPosition, expected: Int) {
        let others = Self.tabs(), current = others[2]
        for user in [true, false] {
            for setting in NewTabPosition.allCases {
                let target = NewTabSlot.target(current: current, pane: others, explicit: position, user: user, setting: setting)
                #expect(Self.index(target, in: others) == expected)
            }
        }
    }

    /// A script's plain `tab new` appends, as before, whatever the person's setting.
    @Test func aScriptsTabNewStillAppends() {
        let others = Self.tabs(), current = others[2]
        for setting in NewTabPosition.allCases {
            #expect(NewTabSlot.target(current: current, pane: others, explicit: nil, user: false, setting: setting) == nil)
        }
    }

    /// At the start means after the pinned tabs, as in Chrome; an empty pane just appends.
    @Test func theStartIsAfterThePinnedTabs() {
        let others = Self.tabs()
        let target = NewTabSlot.target(current: nil, pane: others, explicit: .start, user: true, setting: nil)
        #expect(Self.index(target, in: others) == 1)
        #expect(NewTabSlot.target(current: nil, pane: [], explicit: .start, user: true, setting: nil) == nil)
    }
}
