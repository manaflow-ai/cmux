import Foundation
import Testing
@testable import CmuxNextDaemon

/// Review note 1 of #30279 (comment 6554528009): the close question (`DestructiveConfirmation.runningPrograms`), the quit
/// facts (`QuitFactsReader.foregroundPrograms`) and the session transfer list ask `process-info` for every live pty tab,
/// a Ctrl-` stand-in too. The request boundary refuses a stand-in (rule b) and shows "This pane is still opening" for a
/// read the person never asked for. A stand-in terminal has no process yet: a read of it is never built, so it is never
/// sent; its program is "none yet".
@MainActor struct ProcessInfoStandInTests {
    @Test func aReadOfAStandInIsNotBuilt() {
        #expect(TerminalProcessInfoRequest(reading: ProvisionalTab().surface) == nil, "a process read of a stand-in is built and refused as 'still opening'")
    }

    @Test func aReadOfADaemonSurfaceIsBuiltAndNamesNoStandIn() throws {
        let request = try #require(TerminalProcessInfoRequest(reading: SurfaceID(rawValue: 7)))
        #expect(request.surface == SurfaceID(rawValue: 7))
        #expect(DaemonRequestExecutor.standInReference(in: request) == nil)
    }
}
