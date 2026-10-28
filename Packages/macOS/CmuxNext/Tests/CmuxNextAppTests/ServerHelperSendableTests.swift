@testable import CmuxNextServerHelper
import Foundation
import Testing

/// Task p10-stability-057: the privileged helper's XPC delegate, its service and its fix child are `Sendable`
/// and cross tasks. That they carry no `@unchecked` is held by crash_ratchet.py's `unchecked` row, not here:
/// `crossesTasks` accepts an `@unchecked Sendable` type too. The `Process` is made on the spawn thread and
/// never stored; these tests keep what that child does the same.
@Suite(.timeLimit(.minutes(1)))
struct ServerHelperSendableTests {
    /// Compiles only while `T` is Sendable (checked or `@unchecked`).
    static func crossesTasks<T: Sendable>(_ value: T) async -> T {
        await Task.detached { value }.value
    }

    @Test func theHelpersSharedTypesAreSendableAndCrossTasks() async {
        let service = ServerHelperService(priors: MemoryFixPriorStore())
        #expect(await Self.crossesTasks(service) === service)
        let gate = ServerHelperClientGate(requirement: nil, service: service)
        #expect(await Self.crossesTasks(gate) === gate)
        let child = FixChild(URL(fileURLWithPath: "/usr/bin/true"), [])
        #expect(await Self.crossesTasks(child) === child)
    }

    /// The child runs with no environment at all, exactly as the helper ran it before the process moved to
    /// the spawn thread, and its stdout comes back.
    @Test func aFixChildRunsWithAnEmptyEnvironmentAndReturnsItsOutput() async throws {
        let empty = try await FixChild(URL(fileURLWithPath: "/usr/bin/env"), []).start()
        #expect(empty == FixRunResult(status: 0, output: ""))
        let echoed = try await FixChild(URL(fileURLWithPath: "/bin/echo"), ["custom"]).start()
        #expect(echoed == FixRunResult(status: 0, output: "custom\n"))
    }

    /// A helper without a team (unsigned or ad hoc) refuses every connection.
    @Test func aGateWithoutARequirementRefusesEveryConnection() {
        let gate = ServerHelperClientGate(requirement: nil, service: ServerHelperService(priors: MemoryFixPriorStore()))
        let anonymous = NSXPCListener.anonymous()
        let connection = NSXPCConnection(listenerEndpoint: anonymous.endpoint)
        defer { connection.invalidate() }
        #expect(gate.listener(anonymous, shouldAcceptNewConnection: connection) == false)
    }
}
