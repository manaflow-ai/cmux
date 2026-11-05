import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextAppCore
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// INSTANT OWNER STATUS 15250: Cmd-N's key turn builds and installs the whole workspace view tree
/// (WorkspaceContentController.init, its strip, a full layout sync, the window entry of every pane):
/// 16-18 ms of main thread before the first frame, on every press (Time Profiler, 16 presses, cmux23).
/// Chrome builds that work before the key (the spare renderer) and the key only swaps. The view Cmd-N
/// shows is built off the key's turn: it is in the window before the key, and the key's turn moves it in
/// front, with no new workspace view.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNPrebuiltWorkspaceViewTests {
    @Test func cmdNShowsAWorkspaceViewBuiltBeforeTheKey() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-prebuilt")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let window = try #require(services.windows.active?.window, "no window")
            let before = services.windows.active?.workspaceContent?.contentView

            let store = services.daemon.store
            let workspacesBefore = Set(store.workspaces.map(\.id))
            // Chrome builds the next tab's renderer at a quiet moment, not at the key: the window may build the next
            // Cmd-N's view after this test made this Mac's host known, and before the key.
            try await PasswordManagerRouteTests.until({ Self.descendants(of: window.contentView).contains { $0 is WorkspaceContentView && $0 !== before } },
                                                      within: .seconds(10),
                                                      report: { "Cmd-N built its workspace view in the key's turn: it was not in the window before the key" })
            let viewsBeforeKey = Set(Self.descendants(of: window.contentView).map(ObjectIdentifier.init))

            let work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            }
            let key = try #require(store.workspaces.first { !workspacesBefore.contains($0.id) }?.id, "Cmd-N showed no workspace in its turn")
            // The window swaps its content on the observation turn after the key's.
            try await PasswordManagerRouteTests.until({ services.windows.active?.workspaceContent?.workspace.id == key },
                                                      within: .seconds(2), report: { "the window does not show Cmd-N's workspace" })
            let shown = try #require(services.windows.active?.workspaceContent)
            #expect(shown.contentView !== before, "Cmd-N kept the old workspace's view")
            #expect(viewsBeforeKey.contains(ObjectIdentifier(shown.contentView)),
                    "Cmd-N built its workspace view in the key's turn: it was not in the window before the key")
            for task in work { _ = await task.value }
        }
    }

    /// Memory pressure at warning lets the reservation go: the window's view and the daemon's reserved workspace. The
    /// next Cmd-N builds its view in its own turn (the path before the reservation) and shows a new workspace.
    @Test func memoryPressureReleasesTheReservedWorkspace() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-prebuilt-pressure")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active, "no window")
            let store = services.daemon.store
            try await PasswordManagerRouteTests.until({ controller.reservedContent.ready != nil && store.reservedWorkspace != nil },
                                                      within: .seconds(10), report: { "the window built no next Cmd-N view" })
            let reserved = try #require(store.reservedWorkspace)
            let reservedView = try #require(controller.reservedContent.ready?.contentView)

            services.memoryPressureDidChange(.warning)
            defer { services.memoryPressureDidChange(.normal) }
            #expect(store.reservedWorkspace == nil, "memory pressure kept the daemon's reserved workspace")
            #expect(controller.reservedContent.ready == nil, "memory pressure kept the window's reserved view")
            #expect(reservedView.superview == nil, "the reserved view stayed in the window")

            let workspacesBefore = Set(store.workspaces.map(\.id))
            let work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            }
            let key = try #require(store.workspaces.first { !workspacesBefore.contains($0.id) }?.id, "Cmd-N showed no workspace in its turn")
            #expect(key != reserved.provisional.key.rawValue, "Cmd-N used the released reservation")
            #expect(store.reservedWorkspace == nil, "a workspace was reserved under memory pressure")
            try await PasswordManagerRouteTests.until({ services.windows.active?.workspaceContent?.workspace.id == key },
                                                      within: .seconds(2), report: { "the window does not show Cmd-N's workspace" })
            for task in work { _ = await task.value }
            #expect(store.workspaces.contains { $0.id == key }, "Cmd-N's workspace is gone after its create")
        }
    }

    /// Only a plain Cmd-N (the New Tab page, nothing of its own) takes the reserved workspace; the reservation's folder
    /// is the one a press with no folder of its own gets.
    @Test func onlyAPlainNewTabPageTakesTheReservation() {
        var spawn = WorkspaceSpawn(newTabPage: true)
        #expect(spawn.isPlainNewTabPage)
        #expect(spawn.startFolder(roomFolder: "", local: true, daemonDefault: "/home") == "/home")
        #expect(spawn.startFolder(roomFolder: "/room", local: true, daemonDefault: "/home") == "/room")
        #expect(spawn.startFolder(roomFolder: "/room", local: false, daemonDefault: nil) == nil)
        spawn.inheritedCwd = "/work"
        #expect(spawn.isPlainNewTabPage, "an inherited folder is the press's, given to the page at the key")
        #expect(spawn.startFolder(roomFolder: nil, local: true, daemonDefault: "/home") == "/work")
        let changes: [(inout WorkspaceSpawn) -> Void] = [{ $0.cwd = "/x" }, { $0.command = "ls" }, { $0.firstSession = "s" },
                                                         { $0.key = WorkspaceKey.generate() }, { $0.browserProfile = "p" },
                                                         { $0.firstChat = AgentPaneSeed(cwd: nil) }]
        for change in changes {
            var other = WorkspaceSpawn(newTabPage: true)
            change(&other)
            #expect(!other.isPlainNewTabPage)
        }
        #expect(!WorkspaceSpawn().isPlainNewTabPage)
    }

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
