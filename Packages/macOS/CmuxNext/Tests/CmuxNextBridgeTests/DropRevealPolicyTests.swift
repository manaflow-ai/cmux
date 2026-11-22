import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBridge

/// User decision 2026-10-01: after a user-initiated drop or move the moved
/// tab gets focus and is revealed; Option files it away; automation never
/// changes this client's view unless it asks (`focus: true`).
struct DropRevealPolicyTests {
    let strip = UUID()

    func decide(_ outcome: TabDragOutcome, landed: Bool = true, user: Bool = true, focus: Bool = false, option: Bool = false,
                crosses: Bool = false, active: Bool = true, noActivate: Bool = false, activeSpace: Bool = true) -> DropReveal? {
        DropRevealPolicy.decide(.init(outcome: outcome, landed: landed, userInitiated: user, focusRequested: focus, filesAway: option,
                                      crossesWindows: crosses, appActive: active, noActivate: noActivate, landingOnActiveSpace: activeSpace))
    }

    @Test func aUserDropFocusesTheTabWhereItLands() {
        let focusOnly = DropReveal(focusesTab: true, showsWorkspace: false, makesKey: false)
        #expect(decide(.strip(stripID: strip, index: 0, groupID: nil)) == focusOnly)
        #expect(decide(.newSplit(paneID: "p", edge: .right)) == focusOnly)
        #expect(decide(.newColumn(screenID: "s", afterColumnID: "c")) == focusOnly)
    }

    @Test func aDropIntoAnotherWorkspaceShowsIt() {
        let shows = DropReveal(focusesTab: true, showsWorkspace: true, makesKey: false)
        #expect(decide(.newWorkspace(groupID: nil, index: 2)) == shows)
        #expect(decide(.workspace(id: "w2")) == shows)
    }

    @Test func anotherWindowOrATearOffBecomesKeyOnlyWhenThatIsAllowed() {
        #expect(decide(.strip(stripID: strip, index: 0, groupID: nil), crosses: true)?.makesKey == true)
        #expect(decide(.tearOff(screenPoint: .zero))?.makesKey == true)
        #expect(decide(.tearOff(screenPoint: .zero))?.showsWorkspace == true)
        // The app is not active: never key (a key window in an inactive app).
        #expect(decide(.tearOff(screenPoint: .zero), active: false)?.makesKey == false)
        // A no-activate launch never makes a window key.
        #expect(decide(.strip(stripID: strip, index: 0, groupID: nil), crosses: true, noActivate: true)?.makesKey == false)
        // A window on another Space: focus it there, do not switch Spaces.
        let otherSpace = decide(.strip(stripID: strip, index: 0, groupID: nil), crosses: true, activeSpace: false)
        #expect(otherSpace?.makesKey == false)
        #expect(otherSpace?.focusesTab == true)
    }

    @Test func noChangeForCancelRejectOptionOrAutomation() {
        #expect(decide(.cancel) == nil)
        #expect(decide(.moveWindow(screenPoint: .zero)) == nil)
        #expect(decide(.moveWorkspaceToNewWindow(screenPoint: .zero)) == nil)
        #expect(decide(.moveWorkspace(groupID: nil, index: nil)) == nil)
        // Rejected (an offline or remote owner refused it): focus unchanged.
        #expect(decide(.newWorkspace(groupID: nil, index: nil), landed: false) == nil)
        // Option files it away.
        #expect(decide(.workspace(id: "w2"), option: true) == nil)
        #expect(decide(.tearOff(screenPoint: .zero), option: true) == nil)
        // Automation never changes this client's view...
        #expect(decide(.newWorkspace(groupID: nil, index: nil), user: false) == nil)
        // ...unless it asks.
        #expect(decide(.newWorkspace(groupID: nil, index: nil), user: false, focus: true)?.focusesTab == true)
    }
}
