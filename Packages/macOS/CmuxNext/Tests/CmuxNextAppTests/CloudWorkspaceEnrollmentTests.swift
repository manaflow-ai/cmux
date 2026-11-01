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
            try await enrollment.run(scope: scope, workspace: "workspace", machine: "machine") {
                calls += 1
                start.yield(())
                for await _ in released { break }
            }
        }
        for await _ in started { break }
        let second = Task {
            try await enrollment.run(scope: scope, workspace: "workspace", machine: "machine") {
                calls += 1
                Issue.record("A concurrent attachment must join the running enrollment")
            }
        }
        for await _ in joined { break }
        // A different account must not join the first owner's enrollment.
        try await enrollment.run(scope: .init(user: "other", team: "team_a", origin: scope.origin), workspace: "workspace", machine: "machine") { calls += 1 }
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
            try await enrollment.run(scope: scope, workspace: "workspace", machine: "machine") {
                calls += 1
                throw CancellationError()
            }
        }
        try await enrollment.run(scope: scope, workspace: "workspace", machine: "machine") { calls += 1 }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await enrollment.run(scope: scope, workspace: "workspace", machine: "machine") { calls += 1 }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(calls == 2)
    }
}
