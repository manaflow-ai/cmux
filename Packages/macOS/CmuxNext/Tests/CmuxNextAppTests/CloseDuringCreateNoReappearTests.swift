import AppKit
import CmuxNextActions
import CmuxNextAppCore
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
@testable import CmuxNextSidebar
import Darwin
import Foundation
import Testing

/// Close Workspace pressed while the new workspace's create is in flight takes that create (cx-7cit9); its row
/// leaves at the press and never lists again. The close removed only the create's pending row: the store's own copy
/// of the workspace (the New Tab page's provisional workspace, then the daemon's) listed in its place, at its old
/// slot, until the close landed ("the workspace comes back on the sidebar for a second before disappearing again").
/// The daemon is stopped (SIGSTOP) from the press, so the create is in flight for real, then let go.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloseDuringCreateNoReappearTests {
    @MainActor private final class Seen {
        var moments: [String] = []
    }

    @Test func aCloseThatTakesAnInFlightCreateNeverListsItsWorkspaceAgain() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = controller.state.id
            let sidebar = controller.sidebar.model
            // A second row, so the window keeps one when the new one closes.
            _ = try await services.windows.createWorkspace(WorkspaceSpawn(name: "keep-01"), into: window)
            try await PinnedPageTests.until({ PendingWorkspaceRows.shared.rows(in: window).isEmpty && sidebar.selectableWorkspaces.count >= 2 },
                                            within: .seconds(60), report: { "rows \(sidebar.selectableWorkspaces.count)" })
            let pid = try #require(services.daemon.identity?.pid)
            defer { kill(pid, SIGCONT) }

            #expect(kill(pid, SIGSTOP) == 0)
            var work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("doomed-01")]))
            }
            let key = try #require(PendingWorkspaceRows.shared.rows(in: window).last?.id, "Cmd-N drew no pending row")
            // The press queues its create on a later main-actor turn; a person's next key press comes after that.
            try await PinnedPageTests.until({ WorkspaceLanes.shared.outstandingCreates(in: window) > 0 }, within: .seconds(5),
                                            report: { "the create never entered the window's lane" })
            work += services.registry.capturingWork { _ = services.registry.perform("closeWorkspace") }

            let seen = Seen()
            @MainActor func sample(_ moment: String) {
                if sidebar.allWorkspaces.contains(where: { $0.id.rawValue == key }) { seen.moments.append(moment) }
            }
            sample("at the press")
            // The rows passes after the press, while the create is still in flight.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50)) // test-only: let the sidebar's rows passes run
                sample("while the create runs")
            }
            #expect(kill(pid, SIGCONT) == 0)
            for task in work { _ = await task.value }
            try? await PinnedPageTests.until({
                sample("while the close lands")
                return services.workspace(id: key) == nil && WorkspaceLanes.shared.outstandingCreates(in: window) == 0
            }, within: .seconds(30))
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(50)) // test-only: a late rows pass would list it here
                sample("after the close")
            }
            print("CloseDuringCreateNoReappear: key \(key), listed again \(seen.moments.count) times: \(Set(seen.moments).sorted())")

            #expect(services.workspace(id: key) == nil, "the taken create was not closed")
            #expect(seen.moments.isEmpty, "the closed workspace listed again: \(Set(seen.moments).sorted())")
            #expect(!ClosingWorkspaces.shared.ids.contains(key), "its close hide outlived the workspace")
        }
    }
}
