#if DEBUG
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// `debug.quit {}` only reports the quit state; it never quits. An agent
/// that reads it must learn from the report how to quit a tagged app through
/// its socket (nxdog45-v1: an agent took the report for a failed quit), so
/// it names the quit actions, and each named action is bound and runnable.
@MainActor
struct DebugQuitReportTests {
    @Test func theBareReportNamesTheQuitActions() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let report = try #require(DebugQuit.run([:], services).objectValue)
        #expect(report["quitting"] == .bool(false), "the bare call starts no quit")
        let verbs = try #require(report["quit_with"]?.objectValue, "the report names the quit actions")
        #expect(verbs["method"] == .string("action.run"))
        let named = try #require(verbs["ids"]?.objectValue)
        #expect(named["end_sessions"] == .string("quitEndSessions"), "stops the app and its daemon")
        #expect(named["end_everything"] == .string("quitEndEverything"))
        #expect(named["keep_sessions"] == .string("quitKeepSessions"))
        for case .string(let id) in named.values {
            #expect(services.registry.isBound(ActionID(rawValue: id)), "\(id) is a bound action")
        }
    }
}
#endif
