import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextDaemonService
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

    // MARK: - A daemon that never answers: the bound

    /// A short bound (`DaemonService.closeReplyBound`, 60 s in the product), so the daemon stays stopped past it in seconds.
    private static let shortBound: Duration = .seconds(3)
    /// How long the daemon stays stopped in a bound test: the bound, plus a 1 s process-info lookup and margin.
    private static let pastBound: Duration = .seconds(9)
    /// What the person reads when a close's machine did not answer within the bound: the result is unknown.
    private static let unanswered = "Its machine did not answer, so the workspace may still close."

    /// Each failure of `work`, once it all ended.
    @MainActor private final class Ended {
        var failures: [ActionWorkFailure]?
    }

    /// Awaits `work` in the background; `ended.failures` is set once every task ended.
    private static func awaiting(_ work: [ActionWork], into ended: Ended) -> Task<Void, Never> {
        // task-owner: test-only, awaited by the test before it returns
        Task { @MainActor in
            var failures: [ActionWorkFailure] = []
            for task in work { if let failure = await task.value { failures.append(failure) } }
            ended.failures = failures
        }
    }

    /// The bound's failures as a caller (the CLI, MCP) reads them: each says the close may still apply, as a timeout does
    /// (`mayHaveApplied`, not a refusal), and the person reads the reason.
    private static func checkUnknownResult(_ failures: [ActionWorkFailure]?) {
        #expect(failures?.count == 1, "failures before the daemon went on: \(String(describing: failures))")
        for failure in failures ?? [] {
            #expect(failure.message.hasSuffix(unanswered), "message: \(failure.message)")
            #expect(failure.mayHaveApplied, "a caller is not told the close may still apply")
            #expect(failure.refusal == nil, "an unknown result reads as a refusal")
            #expect(failure.shownReason == unanswered)
        }
    }

    /// After the daemon went on (the closes it queued may now commit), every one of `ids` is in one consistent state:
    /// gone from the store and the sidebar, or listed in both; none is still closing (a hidden row) or still running in a
    /// batch. Waits for the late closes to land; returns how many closed late.
    private static func checkConsistentAfterResume(_ ids: [String], _ services: AppServices, in controller: WindowController) async -> Int {
        let sidebar = controller.sidebar.model
        try? await PinnedPageTests.until({ listed(ids, services).isEmpty }, within: .seconds(20))
        // The sidebar applies the store's removal in its next pass.
        try? await PinnedPageTests.until({ ids.allSatisfy { id in (services.workspace(id: id) != nil) == sidebar.allWorkspaces.contains { $0.id.rawValue == id } } },
                                         within: .seconds(5))
        let closedLate = ids.count - listed(ids, services).count
        for id in ids {
            let inStore = services.workspace(id: id) != nil, inSidebar = sidebar.allWorkspaces.contains { $0.id.rawValue == id }
            #expect(inStore == inSidebar, "\(id): in the store \(inStore), in the sidebar \(inSidebar)")
            #expect(!ClosingWorkspaces.shared.ids.contains(id), "\(id) is still hidden as closing")
            #expect(services.selectionCloses.canStart(id) || !inStore, "\(id) is still counted as a running close")
        }
        return closedLate
    }

    /// Runs `body` with the short bound, the daemon stopped from the start; the daemon goes on after `body`.
    private static func withStoppedDaemon(_ services: AppServices, _ body: @MainActor () async throws -> Void) async throws {
        let pid = try #require(services.daemon.identity?.pid)
        let bound = services.daemon.closeReplyBound
        services.daemon.closeReplyBound = shortBound
        defer {
            services.daemon.closeReplyBound = bound
            kill(pid, SIGCONT)
        }
        #expect(kill(pid, SIGSTOP) == 0)
        try await body()
    }

    /// The sidebar's batch close, with the daemon stopped past the bound: the store still lists every workspace, so every
    /// row is listed again and the person reads that the machine did not answer. Before, the rows stayed hidden for as
    /// long as the daemon did not answer.
    @Test func aBatchCloseThatTheDaemonNeverAnswersListsItsRowsAgainWithTheReason() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let ids = try await Self.make(10, prefix: "hung", services, in: controller)
            let sidebar = controller.sidebar.model
            sidebar.selection = Set(ids.map { CmuxNextSidebar.WorkspaceID($0) })
            var back: [String] = [], toasts: [String] = []
            try await Self.withStoppedDaemon(services) {
                sidebar.send(.close(sidebar.orderedSelection))
                try? await PinnedPageTests.until({ Self.shown(ids, in: sidebar).count == ids.count
                    && CmuxToastCenter.shared.toasts(in: window).contains { $0.message == Self.unanswered } }, within: Self.pastBound)
                back = Self.shown(ids, in: sidebar)
                toasts = CmuxToastCenter.shared.toasts(in: window).map(\.message)
            }
            let closedLate = await Self.checkConsistentAfterResume(ids, services, in: controller)
            let undo = CmuxToastCenter.shared.toasts(in: window).filter { $0.id == Self.toastID }.map(\.message)
            print("WorkspaceCloseSlowDaemon: hung batch of 10, back past the bound \(back.count), toasts \(toasts); "
                + "after the daemon went on, closed late \(closedLate), undo toasts \(undo)")

            #expect(back.count == ids.count, "rows listed again past the bound: \(back.count) of \(ids.count)")
            #expect(toasts.contains(Self.unanswered), "toasts: \(toasts)")
            #expect(!toasts.contains("The workspace could not be closed."), "toasts: \(toasts)")
            // Past the bound none had closed, so no Undo counts them; a close that commits later is in Reopen Closed only.
            #expect(undo.isEmpty, "an Undo toast counts closes that were unknown at the bound: \(undo)")
        }
    }

    /// Close Workspace as the CLI and MCP run it, with the daemon stopped past the bound: the close ends at the bound with
    /// the reason, and its row is listed again.
    @Test func aScriptedCloseThatTheDaemonNeverAnswersEndsAtTheBoundWithTheReason() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let id = try #require(try await Self.make(2, prefix: "hung-one", services, in: controller).last)
            let sidebar = controller.sidebar.model
            let ended = Ended()
            var back: [String] = []
            var waiter: Task<Void, Never>?
            try await Self.withStoppedDaemon(services) {
                let work = services.registry.capturingWork {
                    _ = services.registry.perform("closeWorkspace",
                                                  invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: id), origin: .cli))
                }
                waiter = Self.awaiting(work, into: ended)
                try? await PinnedPageTests.until({ ended.failures != nil }, within: Self.pastBound)
                back = Self.shown([id], in: sidebar)
            }
            let atBound = ended.failures
            await waiter?.value
            let closedLate = await Self.checkConsistentAfterResume([id], services, in: controller)
            print("WorkspaceCloseSlowDaemon: hung scripted close, ended at the bound \(atBound != nil), "
                + "failures \(String(describing: atBound?.map(\.message))), back \(back), closed late \(closedLate)")

            Self.checkUnknownResult(atBound)
            #expect(back == [id], "the row was not listed again")
        }
    }

    /// Close Other Workspaces (one bulk `close-workspaces`) with the daemon stopped past the bound: it ends at the bound
    /// with the reason, as the store still lists the workspaces.
    @Test func closeOtherWorkspacesThatTheDaemonNeverAnswersEndsAtTheBoundWithTheReason() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let ids = try await Self.make(5, prefix: "hung-others", services, in: controller)
            let kept = try #require(ids.first), others = Array(ids.dropFirst())
            let ended = Ended()
            var listed: [String] = []
            var waiter: Task<Void, Never>?
            try await Self.withStoppedDaemon(services) {
                let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: kept), origin: .cli).confirmed()
                let work = services.registry.capturingWork { _ = services.registry.perform("palette.closeOtherWorkspaces", invocation: invocation) }
                waiter = Self.awaiting(work, into: ended)
                try? await PinnedPageTests.until({ ended.failures != nil }, within: Self.pastBound)
                listed = Self.listed(others, services)
            }
            let atBound = ended.failures
            await waiter?.value
            let closedLate = await Self.checkConsistentAfterResume(others, services, in: controller)
            print("WorkspaceCloseSlowDaemon: hung close other, ended at the bound \(atBound != nil), "
                + "failures \(String(describing: atBound?.map(\.message))), listed \(listed.count), closed late \(closedLate)")

            Self.checkUnknownResult(atBound)
            #expect(listed.count == others.count, "the store lost workspaces the daemon did not close")
            #expect(services.workspace(id: kept) != nil, "the kept workspace closed")
        }
    }

    /// The store's decision past the bound (`WorkspaceClose.unanswered`), on the real store: a workspace the store no
    /// longer lists (the close's events came, its reply did not) counts as closed and throws nothing; one it still lists
    /// is an unknown result (`CloseUnanswered`).
    @Test func pastTheBoundTheStoreDecides() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let ids = try await Self.make(3, prefix: "decide", services, in: controller)
            let connection = try #require(services.daemon.connection)
            let gone = try #require(services.workspace(id: ids[1])?.key), kept = try #require(services.workspace(id: ids[2])?.key)
            try await WorkspaceClose.close(gone, terminals: [], on: connection)
            try await PinnedPageTests.until({ services.workspace(id: ids[1]) == nil }, within: .seconds(10))

            var closedThrew: (any Error)?
            do { try await WorkspaceClose.unanswered([gone], on: services.daemon, connection: connection) } catch { closedThrew = error }
            var listedThrew: (any Error)?
            do { try await WorkspaceClose.unanswered([kept], on: services.daemon, connection: connection) } catch { listedThrew = error }
            var mixedThrew: (any Error)?
            do { try await WorkspaceClose.unanswered([gone, kept], on: services.daemon, connection: connection) } catch { mixedThrew = error }
            print("WorkspaceCloseSlowDaemon: store decides, closed \(String(describing: closedThrew)), listed \(String(describing: listedThrew)), "
                + "mixed \(String(describing: mixedThrew))")

            #expect(closedThrew == nil, "a workspace the store no longer lists was not counted as closed")
            #expect(listedThrew is CloseUnanswered, "a workspace the store still lists: \(String(describing: listedThrew))")
            #expect(mixedThrew is CloseUnanswered, "a bulk close with one workspace still listed: \(String(describing: mixedThrew))")
            #expect(services.workspace(id: ids[2]) != nil)
        }
    }
}
