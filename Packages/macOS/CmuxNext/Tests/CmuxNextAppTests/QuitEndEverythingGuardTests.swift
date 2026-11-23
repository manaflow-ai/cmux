@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextSettings
import Testing

/// 2026-10-31 18:46: with `app.quitBehavior: "end-everything"` set, one Cmd-Q
/// typed mid-sentence quit at once and closed all 900 local workspaces (796
/// agent chats, 490 terminals). Cmd-Q now quits the app only (CMUX-630); a
/// scripted quit's remembered End Everything ends the sessions but keeps the
/// workspaces. Only an explicit End Everything (Quit and End Everything in the
/// command palette, `cmux app quit --end-everything`) deletes them.
struct QuitEndEverythingGuardTests {
    /// What `QuitCoordinator` decides with `app.quitBehavior` set to BEHAVIOR.
    private func decide(_ origin: QuitOrigin, behavior: QuitBehavior) -> QuitSessionsChoice {
        QuitRules.decide(origin, remembered: QuitSessionsChoice(rawValue: behavior.rawValue))
    }

    @Test func aRememberedEndEverythingNeverDeletesTheWorkspaces() {
        #expect(decide(.interactive, behavior: .endEverything) == .keep)
        #expect(decide(.scripted, behavior: .endEverything) == .endKeepLayout)
    }

    @Test func anExplicitEndEverythingStillRunsAsAsked() {
        #expect(decide(.explicit(.endEverything), behavior: .keep) == .endEverything)
        #expect(decide(.explicit(.endEverything), behavior: .endEverything) == .endEverything)
    }

    @Test func powerOffAndSignalsNeverEndAnything() {
        #expect(decide(.powerOff, behavior: .endEverything) == .keep)
        #expect(decide(.signal, behavior: .endEverything) == .keep)
    }
}
