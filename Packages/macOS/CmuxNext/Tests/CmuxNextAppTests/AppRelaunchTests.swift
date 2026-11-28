import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemonService
import Testing

/// `cmux app relaunch` (`relaunchKeepSessions`) runs: its catalog row shipped with no App handler, so
/// every build answered "relaunchKeepSessions has no handler in this build" (cmux#53047). The handler is
/// never run here (it quits the process); its decision is.
@MainActor @Suite(.serialized)
struct AppRelaunchTests {
    @Test func relaunchIsBoundWithTheAppsActions() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.isBound("relaunchKeepSessions"))
    }

    @Test func aBareRelaunchKeepsTheSessions() {
        #expect(QuitActions.decideRelaunch(ActionInvocation(origin: .cli), newerInstalled: false) == .relaunch(.keep))
        #expect(QuitActions.decideRelaunch(ActionInvocation(arguments: ["keepSessions": .bool(true)], origin: .cli), newerInstalled: false) == .relaunch(.keep))
    }

    @Test func keepSessionsFalseEndsThemAndKeepsTheLayout() {
        #expect(QuitActions.decideRelaunch(ActionInvocation(arguments: ["keepSessions": .bool(false)], origin: .cli), newerInstalled: true) == .relaunch(.endKeepLayout))
    }

    @Test func ifNewerRefusesTheRunningBuildAndTakesANewerOne() {
        let ifNewer = ActionInvocation(arguments: ["ifNewer": .bool(true)], origin: .cli)
        #expect(QuitActions.decideRelaunch(ifNewer, newerInstalled: false) == .refuse(QuitActions.notNewer))
        #expect(QuitActions.decideRelaunch(ifNewer, newerInstalled: true) == .relaunch(.keep))
    }
}
