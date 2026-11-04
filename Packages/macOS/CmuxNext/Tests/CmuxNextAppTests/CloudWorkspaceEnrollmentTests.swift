import Foundation
import Testing
@testable import CmuxNextCloud

@MainActor @Suite(.timeLimit(.minutes(1))) struct CloudWorkspaceEnrollmentTests {
    private let scope = CloudWorkspaceBindings.Scope(user: "owner", team: "team_a", origin: "https://platform.example")

    @Test func concurrentAttachmentsShareProvisioningAndReconnect() async throws {
        let enrollment = CloudWorkspaceEnrollment()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (joined, join) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        enrollment.joined = { join.yield(()) }
        var calls = 0
        let first = Task {
            try await enrollment.run(scope: scope, machine: "machine") {
                calls += 1
                start.yield(())
                for await _ in released { break }
            }
        }
        for await _ in started { break }
        let second = Task {
            try await enrollment.run(scope: scope, machine: "machine") {
                calls += 1
                Issue.record("A concurrent attachment must join the running enrollment")
            }
        }
        for await _ in joined { break }
        // A different account must not join the first owner's enrollment.
        try await enrollment.run(scope: .init(user: "other", team: "team_a", origin: scope.origin), machine: "machine") { calls += 1 }
        release.yield(())
        try await first.value
        try await second.value
        #expect(calls == 2)
        start.finish(); join.finish(); release.finish()
    }

    @Test func failedEnrollmentCanRetryAndCancelledAttachmentCannotStartOne() async throws {
        let enrollment = CloudWorkspaceEnrollment()
        var calls = 0
        await #expect(throws: CancellationError.self) {
            try await enrollment.run(scope: scope, machine: "machine") {
                calls += 1
                throw CancellationError()
            }
        }
        try await enrollment.run(scope: scope, machine: "machine") { calls += 1 }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await enrollment.run(scope: scope, machine: "machine") { calls += 1 }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(calls == 2)
    }

    @Test func tabsInDifferentWorkspacesOnOneMachineShareOneEnrollment() async throws {
        let enrollment = CloudWorkspaceEnrollment()
        let bindings = CloudWorkspaceBindings()
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa"
        let (started, start) = AsyncStream<Void>.makeStream()
        let (joined, join) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        enrollment.joined = { join.yield(()) }
        var enrolled: [String] = []
        // Each tab proposes its own workspace; the run resolves the machine-wide one.
        func enroll(_ proposed: String) async throws {
            try await enrollment.run(scope: scope, machine: machine) {
                let workspace = try bindings.enrollmentWorkspace(machine: machine, scope: scope, proposed: proposed)
                enrolled.append(workspace)
                start.yield(())
                for await _ in released { break }
                try bindings.remember(workspace: workspace, machine: machine, scope: scope)
            }
        }
        let first = Task { try await enroll("ws_first") }
        for await _ in started { break }
        let second = Task { try await enroll("ws_second") }
        for await _ in joined { break }
        release.yield(())
        try await first.value
        try await second.value
        #expect(enrolled == ["ws_first"])
        // A later tab in a third workspace still sends under the machine's one enrollment, and the
        // first workspace's binding is never replaced.
        #expect(try bindings.enrollmentWorkspace(machine: machine, scope: scope, proposed: "ws_third") == "ws_first")
        #expect(try bindings.bindings(in: scope).map(\.workspace) == ["ws_first"])
        start.finish(); join.finish(); release.finish()
    }
}
