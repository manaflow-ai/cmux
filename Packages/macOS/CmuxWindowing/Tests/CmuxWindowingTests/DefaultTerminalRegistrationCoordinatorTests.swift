import AppKit
import Foundation
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("DefaultTerminalRegistrationCoordinator")
struct DefaultTerminalRegistrationCoordinatorTests {
    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [any Error] = []
        var count: Int { lock.withLock { _errors.count } }
        func record(_ error: any Error) { lock.withLock { _errors.append(error) } }
    }

    /// A registrar whose `setAsDefault()` always fails, used to observe the
    /// failure-presenter routing. The bundle URL is irrelevant for these tests.
    private func failingRegistrar(status: Int32) -> DefaultTerminalRegistrar {
        // `currentStatus()` is not exercised here; `setAsDefault()` fails before
        // any LaunchServices write because LSRegisterURL of a bogus path errors.
        DefaultTerminalRegistrar(
            bundleURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).app"),
            onRegistrationDidChange: {}
        )
    }

    @Test("setAsDefault routes a registration failure to the presenter")
    func failureRoutesToPresenter() async throws {
        let failures = FailureBox()
        let coordinator = DefaultTerminalRegistrationCoordinator(
            makeRegistrar: { self.failingRegistrar(status: -1) },
            onRegistrationFailure: { failures.record($0) }
        )

        coordinator.setAsDefault(debugSource: "test")

        // setAsDefault is fire-and-forget; poll briefly for the async failure.
        for _ in 0..<50 where failures.count == 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(failures.count == 1)
    }

    @Test("A second registerAsDefault joining an in-flight attempt returns false")
    func joiningWaiterReturnsFalse() async throws {
        let coordinator = DefaultTerminalRegistrationCoordinator(
            makeRegistrar: { self.failingRegistrar(status: -1) },
            onRegistrationFailure: { _ in }
        )

        // First call owns the in-flight operation; a concurrent second call must
        // join it and report false (it did not itself perform the registration).
        async let first = try? coordinator.registerAsDefault()
        async let second = try? coordinator.registerAsDefault()
        let results = await [first, second]

        // The joining waiter (the one that saw an in-flight op) returns false;
        // the owner either returns true on success or throws on failure (mapped
        // to nil by `try?`). At least one result must be the joined `false`.
        #expect(results.contains(false))
    }
}
