import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// A daemon that never answers is shown as "connecting" and then, after
/// the startup deadline, as a typed failure; the app keeps retrying.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DaemonStartupStateTests {
    @Test func unreachableDaemonBecomesUnavailableAfterTheDeadline() async throws {
        let service = DaemonService()
        service.startupDeadline = .milliseconds(150)
        let failure = DaemonError.launchFailed("exit 1: the detached session owner did not become ready")
        service.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(backoff: [], terminalEnvironment: nil)) { throw failure }
        }
        defer { service.shutdownConnection() }
        #expect(service.startup == .connecting)
        let view = DaemonConnectingView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.apply(service.startup)
        #expect(view.titleText == Strings.daemonConnecting)

        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(10))
        while !service.startup.isUnavailable, clock.now < end {
            try await clock.sleep(for: .milliseconds(20))
        }
        #expect(service.startup == .unavailable(failure))
        #expect(service.connection == nil)
        view.apply(service.startup)
        #expect(view.titleText == Strings.daemonUnavailable)
    }

    @Test func incompatibleDaemonIsUnavailableAtOnce() async throws {
        let service = DaemonService()
        service.startupDeadline = .seconds(60)
        let failure = DaemonError.unsupportedProtocol(11)
        service.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(backoff: [], terminalEnvironment: nil)) { throw failure }
        }
        defer { service.shutdownConnection() }
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(10))
        while !service.startup.isUnavailable, clock.now < end {
            try await clock.sleep(for: .milliseconds(20))
        }
        #expect(service.startup == .unavailable(failure))
    }
}
