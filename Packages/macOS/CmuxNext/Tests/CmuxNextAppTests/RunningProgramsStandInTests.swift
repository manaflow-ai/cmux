@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// Review of #31875 (Low): `DaemonService.runningPrograms(of:unanswered:)` never asks a stand-in (a terminal still
/// opening). A stand-in has no process, and the daemon refuses a read of its surface, so a close that counts "no answer"
/// as running (`unanswered`, the hidden Cmd-W's read) asked "Still running: <its title>" for a terminal that runs nothing.
@MainActor @Suite struct RunningProgramsStandInTests {
    @Test func aStandInIsNeverAskedAndCountsAsNoProgram() async {
        let standIn = TabModel(TabSnapshot(surface: ProvisionalTab().surface, kind: .pty, title: "opening"))
        let live = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .pty, title: "live"))
        // No connection: every terminal asked counts as `unanswered` says, so only the stand-in's exclusion keeps it out.
        let asked = await DaemonService().runningPrograms(of: [standIn, live]) { $0.title }
        #expect(asked.keys.sorted { $0.rawValue < $1.rawValue } == [live.surface], "a stand-in was asked: \(asked)")
        #expect(asked.programNames == ["live"], "a stand-in counts as a running program: \(asked.programNames)")
    }
}
