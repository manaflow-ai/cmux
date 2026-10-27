import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21, closing several selected sidebar workspaces (#23110's Cmd-W on a selection):
/// "also idk what's going on with these new workspace deletions but it's really slow and it's
/// missing a LOT... and it's also 2 lines tall for some reason". Each selected row ran its own
/// Close Workspace: its own sidebar pass, its own question, and its own turn in the window's lane
/// waiting for the daemon and the store before the next row started. A selection closes as one
/// batch now: every row leaves in one pass, one question covers them all, every close goes out at
/// once, and "Closed N workspaces" with Undo brings them all back. Runs on a same-tree cmux-tui
/// daemon and the real window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SidebarSelectionBatchCloseTests {
    private static let toastID = "workspaces-closed"

    @MainActor private final class Notices {
        var shown: [String] = []
    }

    /// `count` new workspaces in the active window, named `prefix-NN`, once its sidebar lists them all.
    private static func make(_ count: Int, prefix: String, command: String? = nil, _ services: AppServices,
                             in controller: WindowController) async throws -> [String] {
        var ids: [String] = []
        for index in 1...count {
            ids.append(try await services.windows.createWorkspace(WorkspaceSpawn(name: String(format: "\(prefix)-%02d", index), command: command),
                                                                into: controller.state.id))
        }
        let sidebar = controller.sidebar.model
        try await PinnedPageTests.until({ Set(sidebar.selectableWorkspaces.map(\.id.rawValue)).isSuperset(of: ids) }, within: .seconds(60),
                                        report: { "listed \(sidebar.selectableWorkspaces.count) rows" })
        return ids
    }

    private static func listed(_ ids: [String], _ services: AppServices) -> [String] {
        ids.filter { services.workspace(id: $0) != nil }
    }

    @Test func fiftySelectedWorkspacesCloseTogetherAndUndoBringsThemAllBack() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let ids = try await Self.make(50, prefix: "bulk", services, in: controller)
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
            let pressHeld = ContinuousClock.now - pressed
            let leftAtPress = ids.filter { id in sidebar.allWorkspaces.contains { $0.id.rawValue == id } }

            try? await PinnedPageTests.until({ Self.listed(ids, services).isEmpty }, within: .seconds(90))
            let closed = ContinuousClock.now - pressed
            let missed = Self.listed(ids, services)
            try? await PinnedPageTests.until({ CmuxToastCenter.shared.toasts(in: window).contains { $0.id == Self.toastID } }, within: .seconds(5))
            let toasts = CmuxToastCenter.shared.toasts(in: window)
            print("SidebarSelectionBatchClose: 50 rows, press held the main actor \(pressHeld), all closed after \(closed), "
                + "missed \(missed.count), toasts \(toasts.map(\.message)), notices \(notices.shown)")

            #expect(leftAtPress.isEmpty, "rows still shown right after the press: \(leftAtPress.count)")
            #expect(missed.isEmpty, "not closed: \(missed.count) of 50")
            #expect(notices.shown.isEmpty, "notices: \(notices.shown)")
            // One toast for the whole close, on one line of its own: no refusal beside it.
            #expect(toasts.map(\.message) == ["Closed 50 workspaces"], "toasts: \(toasts.map(\.message))")

            let undone = ContinuousClock.now
            #expect(CmuxToastCenter.shared.runAction(id: Self.toastID, in: window))
            let names = Set((1...50).map { String(format: "bulk-%02d", $0) })
            @MainActor func reopened() -> Set<String> { Set(services.daemon.store.workspaces.map { $0.name }).intersection(names) }
            try? await PinnedPageTests.until({ reopened().count == names.count }, within: .seconds(60))
            print("SidebarSelectionBatchClose: undo reopened \(reopened().count) of 50 after \(ContinuousClock.now - undone)")
            #expect(reopened() == names, "not reopened: \(names.subtracting(reopened()).sorted())")
        }
    }

    /// The row menu's Close (and Cmd-W) on one of several selected rows: a selection with running
    /// programs asks one question for all of it, and Close closes every row.
    @Test func aSelectionWithRunningProgramsAsksOnceAndClosesEveryRow() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let idle = try await Self.make(6, prefix: "idle", services, in: controller)
            let busy = try await Self.make(3, prefix: "busy", command: "sleep 600", services, in: controller)
            let ids = idle + busy
            let sidebar = controller.sidebar.model
            sidebar.selection = Set(ids.map { CmuxNextSidebar.WorkspaceID($0) })
            let opened = Notices()
            let dialogs = CmuxDialogCenter.shared
            let token = dialogs.observe { event in if case .opened(let record) = event { opened.shown.append(record.spec.title) } }
            defer { dialogs.stopObserving(token) }

            #expect(services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: ids[0]))))
            // The rows leave at the press, before any terminal answers.
            #expect(ids.allSatisfy { id in !sidebar.allWorkspaces.contains { $0.id.rawValue == id } })
            try await PinnedPageTests.until({ !dialogs.records.isEmpty }, within: .seconds(20))
            // Every row's question would be up by now (process-info answers within a second).
            try? await Task.sleep(for: .seconds(3))
            let asked = opened.shown.count
            for record in dialogs.records where record.spec.identifier == "cmux.dialog.confirmation" {
                _ = dialogs.press(record.id, button: DestructiveConfirmation.confirmID)
            }
            try? await PinnedPageTests.until({ Self.listed(ids, services).isEmpty }, within: .seconds(60))
            print("SidebarSelectionBatchClose: 9 rows (3 running sleep) asked \(asked) questions, missed \(Self.listed(ids, services).count)")
            #expect(asked == 1, "questions asked: \(asked)")
            #expect(Self.listed(ids, services).isEmpty, "not closed: \(Self.listed(ids, services).count) of 9")
        }
    }
}
