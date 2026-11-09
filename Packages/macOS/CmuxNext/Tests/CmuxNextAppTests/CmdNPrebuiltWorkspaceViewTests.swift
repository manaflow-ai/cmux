import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextAppCore
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
            // The window becomes key with this Mac's host known, as at a launch (its idle work may build ahead then).
            services.windows.active?.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
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
            // The window swaps its content in the key's turn (SWITCH STALL 4).
            try await PasswordManagerRouteTests.until({ services.windows.active?.workspaceContent?.workspace.id == key },
                                                      within: .seconds(2), report: { "the window does not show Cmd-N's workspace" })
            let shown = try #require(services.windows.active?.workspaceContent)
            #expect(shown.contentView !== before, "Cmd-N kept the old workspace's view")
            #expect(shown.focusedPane != nil, "the view built before the key has no pane controller")
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
            controller.reservedContent.fill()
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

    /// The race the first green step found: a Cmd-N while the refill is between its reserve and build steps takes the
    /// reservation, and the build step then made a second view of the workspace the window shows (its focused pane went
    /// missing). The press lands at each turn of a refill until one lands between the steps; the window then holds one
    /// view of Cmd-N's workspace (no spare of it) and a focused pane within 2 s.
    @Test func cmdNDuringTheRefillBuildsNoSecondViewOfItsWorkspace() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-prebuilt-race")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active, "no window")
            let store = services.daemon.store
            // From no reservation: the window's launch show may have built one already, and a fill then does nothing.
            controller.reservedContent.drop()
            services.agentTabs.releaseReservedWorkspace(on: store, .unshown)
            controller.reservedContent.fill()
            // The first turn that shows the reservation made with no view mounted yet: the refill is between its steps.
            let deadline = ContinuousClock.now + .seconds(20)
            while !(store.reservedWorkspace != nil && controller.reservedContent.ready == nil), ContinuousClock.now < deadline { await Task.yield() }
            try #require(store.reservedWorkspace != nil && controller.reservedContent.ready == nil, "the refill never stood between its steps")
            let before = Set(store.workspaces.map(\.id))
            let work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            }
            let key = try #require(store.workspaces.first { !before.contains($0.id) }?.id, "Cmd-N showed no workspace in its turn")
            try await PasswordManagerRouteTests.until({
                services.windows.active?.workspaceContent?.workspace.id == key && services.windows.active?.workspaceContent?.focusedPane != nil
            }, within: .seconds(2), report: { "the window shows no focused pane of Cmd-N's workspace" })
            // The refill's later steps run (and any refill after the key): the slot settles before the check.
            try await PasswordManagerRouteTests.until({ !controller.reservedContent.isFilling },
                                                      within: .seconds(10), report: { "the window's refill never settled" })
            let shown = try #require(controller.workspaceContent)
            #expect(controller.reservedContent.ready?.workspace !== shown.workspace, "the refill built a second view of the shown workspace")
            let views = controller.root.contentHost.subviews.filter { $0 is WorkspaceContentView }
            let known = 1 + controller.parked.count + (controller.reservedContent.ready == nil ? 0 : 1)
            #expect(views.count == known, "the window holds \(views.count) workspace views; its shown, parked and spare ones are \(known)")
            for task in work { _ = await task.value }
        }
    }

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
