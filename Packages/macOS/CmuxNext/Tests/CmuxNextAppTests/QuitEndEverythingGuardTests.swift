@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextSettings
import Testing

/// 2026-10-31 18:46: with `app.quitBehavior: "end-everything"` set, one Cmd-Q
/// typed mid-sentence quit at once and closed all 900 local workspaces (796
/// agent chats, 490 terminals). A remembered choice never deletes workspaces:
/// with no quit alert (Leo 2026-11-05), Cmd-Q and a scripted quit end the
/// sessions but keep the workspaces. Only an explicit End Everything (Quit and
/// End Everything in the cmux menu or the command palette, `cmux app quit
/// --end-everything`) deletes them.
struct QuitEndEverythingGuardTests {
    @Test func aRememberedEndEverythingKeepsTheWorkspacesOnCmdQ() {
        #expect(QuitPolicy.decide(.interactive, behavior: .endEverything) == .endKeepLayout)
        #expect(QuitPolicy.decide(.scripted, behavior: .endEverything) == .endKeepLayout)
    }

    @Test func anExplicitEndEverythingStillRunsAsAsked() {
        #expect(QuitPolicy.decide(.explicit(.endEverything), behavior: .keep) == .endEverything)
        #expect(QuitPolicy.decide(.explicit(.endEverything), behavior: .endEverything) == .endEverything)
    }

    @Test func powerOffAndSignalsNeverEndAnything() {
        #expect(QuitPolicy.decide(.powerOff, behavior: .endEverything) == .keep)
        #expect(QuitPolicy.decide(.signal, behavior: .endEverything) == .keep)
    }
}
