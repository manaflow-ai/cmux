import Foundation
import Testing
@testable import CmuxNextDaemon

/// The "This pane is still opening" toast right after Cmd-N then Ctrl-` (#29530 rate probe, about one per cycle on base
/// and head, STATUS 2258): a resource read (`terminal-resources`: debug.surfaces' host pids, the Task Manager, the
/// resource cards, memory-pressure hibernation, the quit facts) named the Ctrl-` stand-in tab's surface, which the
/// request boundary refuses as a pane still opening (rule b) and shows to the person as a refusal of an action they did
/// not take. A stand-in terminal has no daemon process yet: the read asks only for daemon surfaces, and is sent.
@MainActor struct TerminalResourcesStandInTests {
    @Test func aResourceReadNamesNoStandInSurfaceAndIsSent() throws {
        let standIn = ProvisionalTab().surface
        let daemon = SurfaceID(rawValue: 7)
        let request = TerminalResourcesRequest(surfaces: [daemon, standIn])
        #expect(DaemonRequestExecutor.standInReference(in: request) == nil, "the read names the stand-in surface \(standIn.rawValue): it is refused as 'still opening'")
        #expect(request.surfaces == [daemon])
        let line = try WireCoding.encodeRequest(request, id: 3)
        #expect(!DaemonRequestExecutor.mayNameStandIn(line), "the encoded read names a stand-in")
    }

    /// Only stand-ins: an empty list, which asks the daemon for no terminal (never nil, which asks for every one).
    @Test func aReadOfOnlyStandInsAsksForNoTerminal() {
        let request = TerminalResourcesRequest(surfaces: [ProvisionalTab().surface])
        #expect(request.surfaces == [])
        #expect(DaemonRequestExecutor.standInReference(in: request) == nil)
        #expect(TerminalResourcesRequest(surfaces: nil).surfaces == nil)
    }
}
