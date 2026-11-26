import CmuxNextAppCore
import Testing

/// Launch-TTI round 11: `workspace focus l5-b` during a cold launch, before the saved state loaded, and the front
/// window still showed l5-a on its terminal: the restore's adopt of the saved front window put its saved workspace
/// back. A workspace picked since the launch window showed now outlives the saved one.
struct LaunchFocusChoiceTests {
    let launch = LaunchFocusChoice(shownAtLaunch: "l5-a")

    @Test func aWorkspaceFocusedDuringTheLaunchOutlivesTheSavedOne() {
        #expect(launch.keptWorkspace(now: "l5-b", listed: { ["l5-a", "l5-b"].contains($0) }) == "l5-b")
    }

    @Test func untouchedTheSavedWorkspaceStays() {
        #expect(launch.keptWorkspace(now: "l5-a", listed: { _ in true }) == nil)
        #expect(launch.keptWorkspace(now: nil, listed: { _ in true }) == nil, "the empty state is no choice")
    }

    @Test func aWorkspaceTheRestoredWindowDoesNotListIsNotKept() {
        #expect(launch.keptWorkspace(now: "elsewhere", listed: { $0 == "l5-a" }) == nil)
    }

}
