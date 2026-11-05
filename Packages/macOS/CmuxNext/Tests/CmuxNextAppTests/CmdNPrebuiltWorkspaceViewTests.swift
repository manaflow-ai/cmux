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

            let viewsBeforeKey = Set(Self.descendants(of: window.contentView).map(ObjectIdentifier.init))

            let work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            }
            let shown = try #require(services.windows.active?.workspaceContent, "Cmd-N showed no workspace in its turn")
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
