import AppKit
import CmuxNextActions
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

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
