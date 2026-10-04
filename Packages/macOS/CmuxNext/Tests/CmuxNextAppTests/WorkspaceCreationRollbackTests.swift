@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A new workspace whose first terminal cannot be created is closed again
/// and reported once; the empty-workspace repair never fills it (live
/// report: "new workspace: create-terminal failed" left an empty workspace,
/// which the repair then gave a terminal).
@MainActor
struct WorkspaceCreationRollbackTests {
    struct TerminalFailed: Error, Equatable {}
    final class Log { var closed: [WorkspaceKey] = []; var created: [WorkspaceKey] = [] }

    private static let key = WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02")

    @Test func aFailedFirstTerminalClosesTheNewWorkspaceAndThrowsOnce() async {
        let log = Log()
        var thrown: [any Error] = []
        do {
            _ = try await WorkspaceCreation.withTerminal(
                createWorkspace: { Self.key },
                createTerminal: { _ in throw TerminalFailed() },
                closeWorkspace: { log.closed.append($0) }
            )
        } catch {
            thrown.append(error)
        }
        #expect(log.closed == [Self.key], "the half-created workspace was left open")
        #expect(thrown.count == 1)
        #expect(thrown.first is TerminalFailed, "the user must see the terminal failure, not a close error")
    }

    @Test func theRepairNeverFillsAWorkspaceWhoseCreateFailed() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "failed"),
        ]))
        let log = Log()
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.create = { key in
            log.created.append(key)
            return SurfaceID(rawValue: 42)
        }
        await #expect(throws: TerminalFailed.self) {
            try await services.emptyWorkspaces.populating(Self.key) { () async throws -> Void in throw TerminalFailed() }
        }
        let workspace = try #require(services.daemon.store.workspaces.first)
        services.emptyWorkspaces.check(workspace) { _ in }
        for _ in 0..<200 { await Task.yield() }
        #expect(log.created.isEmpty, "the repair gave a terminal to a workspace whose create failed")
        withExtendedLifetime(services) {}
    }
}
