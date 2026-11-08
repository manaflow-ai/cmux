import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-11-05: "i tried to close a bunch of workspaces, but they all suddenly came back",
/// "it says it closed 919 but clearly sidebar doesnt show it closed", "i cant close workspace0926", and
/// Cmd-Shift-P's Close Workspaces Below on a pinned workspace refused with "the workspace is not in
/// the sidebar". The app's log: `layout.bulk failed: unknown surface 166888` (one stale tab failed the
/// whole bulk), then 641 × `close-workspace failed: surface request queue is full` (every workspace
/// with no tab closed as its own request, all at once, past the connection's 256-request queue). Each
/// refusal listed its row again, under a "Closed 919 workspaces" toast shown before any reply.
/// Now one request per daemon closes them all (`layout-bulk-bare-v1`), rows stay closing until the
/// daemon answers, and the toast counts what closed. Runs on a same-tree cmux-tui and the real window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(10)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClosedWorkspacesStayClosedTests {
    private static let toastID = "workspaces-closed"

    @MainActor private final class Notices {
        var shown: [String] = []
    }

    /// `empty` workspaces with no tab, then `full` with a terminal, named `tag-NNN`, once the window's sidebar
    /// lists them all. Returns their app ids.
    private static func make(empty: Int, full: Int, tag: String, _ services: AppServices, _ connection: DaemonConnection,
                             in controller: WindowController) async throws -> [String] {
        var created: [ResourceID] = []
        for index in 0..<(empty + full) {
            created.append(try await connection.state.createWorkspace(name: String(format: "\(tag)-%03d", index), ephemeral: false,
                                                                      terminal: index >= empty, focus: false).workspaceID)
        }
        let store = services.daemon.store
        @MainActor func ids() -> [String] { created.compactMap { id in store.workspaces.first { $0.resourceID == id && $0.key != nil }?.id } }
        let sidebar = controller.sidebar.model
        try await PinnedPageTests.until({ ids().count == created.count && Set(sidebar.selectableWorkspaces.map(\.id.rawValue)).isSuperset(of: ids()) },
                                        within: .seconds(120), report: { "listed \(sidebar.selectableWorkspaces.count) rows, \(ids().count) in the store" })
        return ids()
    }

    private static func listed(_ ids: [String], _ services: AppServices) -> [String] {
        ids.filter { services.workspace(id: $0) != nil }
    }

    /// Every refusal shown while `body` runs.
    private static func notices(_ services: AppServices, _ body: () async throws -> Void) async rethrows -> [String] {
        let notices = Notices()
        let shows = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            if !quiet { notices.shown.append(reason) }
            shows?(reason, quiet)
        }
        defer { services.registry.refusalObserver = shows }
        try await body()
        return notices.shown
    }

    private static func toast(in window: NSWindow) -> String? {
        CmuxToastCenter.shared.toasts(in: window).first { $0.id == toastID }?.message
    }

    /// The sidebar's Delete (Cmd-W, the row menu's Close) on 400 selected rows, 380 of them with no tab: every
    /// row closes and stays closed, with no refusal, and the toast shows once they have, with their count.
    @Test func fourHundredSelectedRowsMostlyEmptyCloseAndStayClosed() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let ids = try await Self.make(empty: 380, full: 20, tag: "many", services, connection, in: controller)
            let sidebar = controller.sidebar.model
            var atToast: [String] = []
            let shown = try await Self.notices(services) {
                sidebar.selection = Set(ids.map { CmuxNextSidebar.WorkspaceID($0) })
                sidebar.send(.close(sidebar.orderedSelection))
                try? await PinnedPageTests.until({ Self.toast(in: window) != nil || !shownRefusals(services).isEmpty }, within: .seconds(120))
                atToast = Self.listed(ids, services)
                try? await PinnedPageTests.until({ Self.listed(ids, services).isEmpty }, within: .seconds(30))
            }
            let back = Self.listed(ids, services)
            print("ClosedWorkspacesStayClosed: 400 rows, listed at the toast \(atToast.count), listed after \(back.count), "
                + "toast \(Self.toast(in: window) ?? "none"), notices \(shown.prefix(3))")
            #expect(shown.isEmpty, "refusals: \(shown.count), first \(shown.first ?? "")")
            #expect(atToast.isEmpty, "\(atToast.count) rows were listed again when the toast showed")
            #expect(back.isEmpty, "\(back.count) of 400 came back")
            #expect(Self.toast(in: window) == "Closed 400 workspaces")
        }
    }

    /// Cmd-Shift-P's Close Other Workspaces over 300 workspaces, 290 with no tab: the toast shows only once
    /// they have closed, says how many did, and none comes back.
    @Test func closeOtherWorkspacesToastsWhatClosedAfterItClosed() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let anchor = try #require(controller.state.workspaceID)
            let ids = try await Self.make(empty: 290, full: 10, tag: "others", services, connection, in: controller)
            var atToast: [String] = []
            let shown = try await Self.notices(services) {
                let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: anchor), origin: .user).confirmed()
                #expect(services.registry.perform("palette.closeOtherWorkspaces", invocation: invocation))
                try? await PinnedPageTests.until({ Self.toast(in: window) != nil }, within: .seconds(120))
                atToast = Self.listed(ids, services)
                try? await PinnedPageTests.until({ Self.listed(ids, services).isEmpty }, within: .seconds(30))
            }
            let back = Self.listed(ids, services)
            let toast = Self.toast(in: window)
            print("ClosedWorkspacesStayClosed: close others of 300, listed at the toast \(atToast.count), after \(back.count), toast \(toast ?? "none")")
            #expect(shown.isEmpty, "refusals: \(shown.count), first \(shown.first ?? "")")
            #expect(atToast.isEmpty, "the toast showed while \(atToast.count) rows were still open")
            #expect(back.isEmpty, "\(back.count) of 300 came back")
            #expect(toast?.hasPrefix("Closed ") == true && toast?.hasSuffix(" workspaces") == true, "toast: \(toast ?? "none")")
            #expect(services.workspace(id: anchor) != nil, "the anchor stays")
        }
    }

    /// Close Workspaces Below from Cmd-Shift-P with a pinned workspace shown: a pinned workspace draws in Pinned,
    /// above the list, so every list row is below it. Before, the close was refused with "the workspace is
    /// not in the sidebar".
    @Test func closeWorkspacesBelowAPinnedWorkspaceClosesTheList() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let ids = try await Self.make(empty: 3, full: 3, tag: "below", services, connection, in: controller)
            let pinned = try #require(ids.last)
            try PinCommands(context: AppActionContext(services: services)).setWorkspacePinned(pinned, pinned: true, origin: .cli)
            let sidebar = controller.sidebar.model
            try await PinnedPageTests.until({ !sidebar.selectableWorkspaces.contains { $0.id.rawValue == pinned } }, within: .seconds(30),
                                            report: { "the pinned workspace is still a list row" })
            let rows = ids.dropLast().map { $0 }
            var reason: String?
            var work: [ActionWork] = []
            reason = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: pinned), origin: .user).confirmed()
                    _ = services.registry.perform("palette.closeWorkspacesBelow", invocation: invocation)
                }
            }
            for task in work { _ = await task.value }
            #expect(reason == nil, "refused: \(reason ?? "")")
            try? await PinnedPageTests.until({ Self.listed(rows, services).isEmpty }, within: .seconds(30))
            #expect(Self.listed(rows, services).isEmpty, "still open below the pinned workspace: \(Self.listed(rows, services).count)")
            #expect(services.workspace(id: pinned) != nil, "the pinned workspace stays")
        }
    }
}

/// The refusals the window shows now (the toast center's other toasts).
@MainActor private func shownRefusals(_ services: AppServices) -> [String] {
    guard let window = services.windows.active?.window else { return [] }
    return CmuxToastCenter.shared.toasts(in: window).filter { $0.id != "workspaces-closed" }.map(\.message)
}
