import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Darwin
import Foundation
import Testing

/// A close that the daemon answers after the 2 s control deadline is a close, not a refusal. Under parallel load a
/// batch close of 50 selected rows (`WorkspaceSelectionCloseFlow`) was closed by the daemon in 11.7 s, but each
/// `close-workspace` gave up at its 2 s client deadline (`DaemonConnection.defaultRequestTimeout`): the person saw
/// "The workspace could not be closed." beside "Closed 12 workspaces", the rows came back, and Undo reopened only 12.
/// The daemon is slow here for real: stopped (SIGSTOP) right after the press, for longer than the deadline, then let go.
/// Every close path shares `WorkspaceClose.close`; the batch (the sidebar's Delete, Cmd-W and the row menu on a
/// selection) and Close Workspace as the CLI and MCP run it (`action.run`, origin `.cli`) are driven here.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceCloseSlowDaemonTests {
    private static let toastID = "workspaces-closed"
    /// How long the daemon stays stopped after the press: the batch first asks the terminals for a running program
    /// (each lookup gives up after 1 s), then sends its closes, so their replies come well past the 2 s deadline.
    private static let stopped: Duration = .seconds(6)

    @MainActor private final class Notices {
        var shown: [String] = []
    }

    /// `count` new workspaces in the active window, named `prefix-NN`, once its sidebar lists them all.
    private static func make(_ count: Int, prefix: String, _ services: AppServices, in controller: WindowController) async throws -> [String] {
        var ids: [String] = []
        for index in 1...count {
            ids.append(try await services.windows.createWorkspace(WorkspaceSpawn(name: String(format: "\(prefix)-%02d", index)),
                                                                into: controller.state.id))
        }
        let sidebar = controller.sidebar.model
        try await PinnedPageTests.until({ Set(sidebar.selectableWorkspaces.map(\.id.rawValue)).isSuperset(of: ids) }, within: .seconds(60),
                                        report: { "listed \(sidebar.selectableWorkspaces.count) rows" })
        return ids
    }

    /// The rows of `ids` the sidebar shows and that are not closing (listed again after a refusal).
    private static func shown(_ ids: [String], in sidebar: SidebarModel) -> [String] {
        ids.filter { id in sidebar.allWorkspaces.contains { $0.id.rawValue == id } && !ClosingWorkspaces.shared.ids.contains(id) }
    }

    private static func listed(_ ids: [String], _ services: AppServices) -> [String] {
        ids.filter { services.workspace(id: $0) != nil }
    }

    /// Stops the daemon for `stopped`, then lets it go; it is let go on a throw too.
    private static func stopDaemon(_ pid: pid_t, whileStopped: @MainActor () -> Void = {}) async {
        #expect(kill(pid, SIGSTOP) == 0)
        try? await Task.sleep(for: stopped) // test-only: the daemon answers past the 2 s deadline
        whileStopped()
        #expect(kill(pid, SIGCONT) == 0)
    }

    @Test func fiftySelectedWorkspacesCloseWhenTheDaemonAnswersAfterTheDeadline() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let ids = try await Self.make(50, prefix: "late", services, in: controller)
            let pid = try #require(services.daemon.identity?.pid)
            defer { kill(pid, SIGCONT) }
            let notices = Notices()
            let shows = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in
                if !quiet { notices.shown.append(reason) }
                shows?(reason, quiet)
            }
            defer { services.registry.refusalObserver = shows }

            // The sidebar's Delete key on the selection (Cmd-W and the row menu's Close send the same intent).
            let sidebar = controller.sidebar.model
            sidebar.selection = Set(ids.map { CmuxNextSidebar.WorkspaceID($0) })
            let pressed = ContinuousClock.now
            sidebar.send(.close(sidebar.orderedSelection))
            // A row that came back while the daemon was slow: the close took it back on the client clock.
            var cameBack: [String] = []
            var refusedWhileSlow: [String] = []
            await Self.stopDaemon(pid) {
                cameBack = Self.shown(ids, in: sidebar)
                refusedWhileSlow = CmuxToastCenter.shared.toasts(in: window).map(\.message)
            }

            try? await PinnedPageTests.until({ Self.listed(ids, services).isEmpty }, within: .seconds(90))
            let missed = Self.listed(ids, services)
            try? await PinnedPageTests.until({ CmuxToastCenter.shared.toasts(in: window).contains { $0.id == Self.toastID } }, within: .seconds(20))
            let toasts = CmuxToastCenter.shared.toasts(in: window)
            print("WorkspaceCloseSlowDaemon: 50 rows, all closed after \(ContinuousClock.now - pressed), missed \(missed.count), "
                + "back while slow \(cameBack.count), toasts while slow \(refusedWhileSlow), toasts \(toasts.map(\.message)), notices \(notices.shown)")

            #expect(cameBack.isEmpty, "rows listed again while the daemon was slow: \(cameBack.count) of 50")
            #expect(missed.isEmpty, "not closed: \(missed.count) of 50")
            #expect(notices.shown.isEmpty, "notices: \(notices.shown)")
            #expect(toasts.map(\.message) == ["Closed 50 workspaces"], "toasts: \(toasts.map(\.message))")

            // Undo brings back every workspace the daemon closed.
            #expect(CmuxToastCenter.shared.runAction(id: Self.toastID, in: window))
            let names = Set((1...50).map { String(format: "late-%02d", $0) })
            @MainActor func reopened() -> Set<String> { Set(services.daemon.store.workspaces.map { $0.name }).intersection(names) }
            try? await PinnedPageTests.until({ reopened().count == names.count }, within: .seconds(60))
            #expect(reopened() == names, "not reopened: \(names.subtracting(reopened()).sorted())")
        }
    }

    /// Close Workspace as `cmux workspace close` and MCP run it (`action.run`, origin `.cli`, nothing to ask): the
    /// row leaves at once and stays gone while the daemon is slow, and the close reports no failure.
    @Test func aScriptedCloseThatTheDaemonAnswersAfterTheDeadlineIsNoRefusal() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let id = try #require(try await Self.make(2, prefix: "late-one", services, in: controller).last)
            let pid = try #require(services.daemon.identity?.pid)
            defer { kill(pid, SIGCONT) }
            let sidebar = controller.sidebar.model

            let work = services.registry.capturingWork {
                _ = services.registry.perform("closeWorkspace",
                                              invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: id), origin: .cli))
            }
            var cameBack: [String] = []
            await Self.stopDaemon(pid) { cameBack = Self.shown([id], in: sidebar) }
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            try? await PinnedPageTests.until({ services.workspace(id: id) == nil }, within: .seconds(30))
            let toasts = CmuxToastCenter.shared.toasts(in: window).map(\.message)
            print("WorkspaceCloseSlowDaemon: one scripted close, back while slow \(cameBack), failures \(failures), toasts \(toasts)")

            #expect(work.count == 1, "the close reported \(work.count) tasks")
            #expect(cameBack.isEmpty, "the row was listed again while the daemon was slow")
            #expect(failures.isEmpty, "failed: \(failures)")
            #expect(services.workspace(id: id) == nil, "not closed")
            #expect(!toasts.contains("The workspace could not be closed."), "toasts: \(toasts)")
        }
    }

    /// Close Other Workspaces (the palette, the row menu, `cmux workspace close-other`): one bulk close
    /// (`close-workspaces`, BulkClosePlan) the daemon answers past the deadline reports no failure and closes them all.
    @Test func closeOtherWorkspacesThatTheDaemonAnswersAfterTheDeadlineIsNoFailure() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let ids = try await Self.make(8, prefix: "late-others", services, in: controller)
            let kept = try #require(ids.first), others = Array(ids.dropFirst())
            let pid = try #require(services.daemon.identity?.pid)
            defer { kill(pid, SIGCONT) }

            let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: kept), origin: .cli).confirmed()
            var ran = false
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork { ran = services.registry.perform("palette.closeOtherWorkspaces", invocation: invocation) }
            }
            await Self.stopDaemon(pid)
            var failures = refusal.map { [$0] } ?? []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            try? await PinnedPageTests.until({ Self.listed(others, services).isEmpty }, within: .seconds(30))
            print("WorkspaceCloseSlowDaemon: close other workspaces, ran \(ran), tasks \(work.count), failures \(failures), "
                + "left \(Self.listed(others, services).count) of \(others.count)")

            #expect(ran)
            #expect(failures.isEmpty, "failed: \(failures)")
            #expect(Self.listed(others, services).isEmpty, "not closed: \(Self.listed(others, services).count) of \(others.count)")
            #expect(services.workspace(id: kept) != nil, "the kept workspace closed")
        }
    }
}
