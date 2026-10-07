import CmuxNextDaemon
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// A daemon that never answers is shown as "connecting" and then, after
/// the startup deadline, as a typed failure; the app keeps retrying.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DaemonStartupStateTests {
    private func waitFor(_ expected: DaemonStartupState, service: DaemonService,
                         timeout: Duration = .seconds(10)) async throws {
        let observation = Task { @MainActor () -> Bool in
            for await state in Observations({ service.startup }) where state == expected { return true }
            return false
        }
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(for: timeout)
        }
        let observed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await observation.value }
            group.addTask {
                await timeoutTask.value
                return false
            }
            let result = await group.next() ?? false
            observation.cancel()
            timeoutTask.cancel()
            group.cancelAll()
            return result
        }
        guard observed else {
            throw DaemonError.timedOut("daemon startup state did not become \(expected)")
        }
    }

    @Test func unreachableDaemonBecomesUnavailableAfterTheDeadline() async throws {
        let service = DaemonService()
        let clock = ManualClock()
        service.startupClock = clock
        service.startupDeadline = .milliseconds(150)
        let failure = DaemonError.launchFailed("exit 1: the detached session owner did not become ready")
        service.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil)) { throw failure }
        }
        defer { service.shutdownConnection() }
        #expect(service.startup == .connecting)
        let view = DaemonConnectingView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.apply(service.startup)
        #expect(view.titleText == Strings.daemonConnecting)

        // The deadline and the first reconnect backoff both use this clock;
        // wait until both are armed so advancing the clock always crosses the
        // startup deadline, even if the failure callback is scheduled first.
        await clock.sleepers(atLeast: 2)
        clock.advance(by: service.startupDeadline)
        try await waitFor(.unavailable(failure), service: service)
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
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil)) { throw failure }
        }
        defer { service.shutdownConnection() }
        try await waitFor(.unavailable(failure), service: service)
        #expect(service.startup == .unavailable(failure))
    }
}
