import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// "Make sure restoration works with multiple windows" (Lawrence 2026-10-28): three windows, each
/// at its own frame with its own sidebar state, one showing a terminal, one a terminal with a
/// browser tab beside it, one on a second space; quit (the quit path's flush), relaunch on the
/// same daemon, as after Quit and Keep Sessions or an update relaunch. Every window comes back
/// at its frame, in its space, showing the workspace it showed, with its sidebar as it was and
/// the front window still in front, and no shown pane stays "Restoring…" or blank. The boundary:
/// the app's services on a real same-tree daemon, the window records in its `personal`
/// projection, and a second set of services that connects to that daemon as a relaunch does.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct MultiWindowRestoreTests {
    /// What one window showed before the quit.
    private struct Saved {
        var id: String
        var frame: CGRect
        var workspace: String
        var profile: ProfileID
        var sidebarHidden: Bool
        var sidebarWidth: Double?
        var tabKinds: [String]
    }

    /// `noActivate`: launched with `CMUX_NEXT_NO_ACTIVATE=1` (agents, capture slots): no window takes
    /// key, and the front window must still come back in front (the restore journey saw it ordered
    /// behind the other two, last in the saved order).
    @Test(arguments: [false, true]) func threeWindowsComeBackAsTheyWere(noActivate: Bool) async throws {
        let wasNoActivate = WindowPlacement.noActivate
        WindowPlacement.noActivate = noActivate
        defer { WindowPlacement.noActivate = wasNoActivate }
        try await Self.withDaemon { launcher in
            let before = try await Self.launch(launcher)
            var saved: [Saved] = []
            var front = ""
            let seeded = await Self.capture {
                let frames = Self.frames()
                // Window 1: the launch window's workspace (a terminal), sidebar dragged wider.
                let first = try #require(before.windows.active)
                try #require(first.window).setFrame(frames[0], display: true)
                first.sidebar.model.width = 312

                // Window 2: a new window with a terminal, then a browser tab in the same pane; sidebar hidden.
                let secondID = UUID().uuidString.lowercased()
                let secondWorkspace = try #require(await before.windows.createWorkspace(into: secondID, frame: frames[1]))
                try await Self.until({ Self.livePane(before, window: secondID, workspace: secondWorkspace) != nil })
                let second = try #require(before.windows.controller(for: secondID))
                let page = try Self.pageFile()
                let pane = try #require(Self.livePane(before, window: secondID, workspace: secondWorkspace))
                #expect(pane.newBrowserTab(url: page))
                try await Self.until({ pane.pane.tabs.contains { $0.kind == .browser } },
                                     report: { "tabs \(pane.pane.tabs.map(\.kind))" })
                second.sidebar.model.presentation = .hidden

                // Window 3: a second space opened in a new window (Open Space in New Window's path).
                let connection = try #require(before.daemon.connection)
                let room = try await connection.createProfile(name: "mw-room")
                // The reply comes before the app's mirror of the room; a person's space already exists.
                await before.machines.local.store.mirrored(profile: room.id)
                let thirdID = UUID().uuidString.lowercased()
                before.windows.state(for: thirdID).enterProfile(room.id)
                let thirdWorkspace = try await before.windows.createWorkspace(WorkspaceSpawn(profile: room.id), into: thirdID, frame: frames[2])
                try await Self.until({ Self.livePane(before, window: thirdID, workspace: thirdWorkspace) != nil })

                // The person last used window 1: it is key and first in the window order.
                try #require(first.window).makeKeyAndOrderFront(nil)
                before.windows.didActivate(first)
                front = first.state.id

                for controller in [first, second, try #require(before.windows.controller(for: thirdID))] {
                    let window = try #require(controller.window)
                    let workspace = try #require(controller.state.workspaceID)
                    let tabs = controller.workspaceContent?.panes.values.flatMap { $0.pane.tabs.map { "\($0.kind)" } }.sorted() ?? []
                    saved.append(Saved(id: controller.state.id, frame: window.frame, workspace: workspace,
                                       profile: controller.state.profileID, sidebarHidden: controller.state.sidebarHidden,
                                       sidebarWidth: controller.state.sidebarHidden ? nil : controller.state.sidebarWidth,
                                       tabKinds: tabs))
                }
                #expect(saved[2].profile == room.id, "window 3 is not on the new space")
                await before.windows.prepareForTermination()
                let records = await before.daemon.windowState?.document.windows ?? []
                for window in saved {
                    #expect(records.contains { $0.id == window.id && !$0.isClosed }, "window \(window.id) has no open record: \(records.map(\.id))")
                }
            }
            await Self.quit(before, endingDaemon: (try? seeded.get()) == nil)
            try seeded.get()

            let after = try await Self.launch(launcher)
            let restored = await Self.capture {
                // Every window, each shown with live content (no pane "Restoring…" or blank).
                try await Self.until({
                    saved.allSatisfy { window in
                        guard let controller = after.windows.controller(for: window.id) else { return false }
                        return controller.window?.isVisible == true && controller.workspaceContent?.workspace.id == window.workspace
                    } && Self.unsettledPanes(after).isEmpty
                }, within: .seconds(60), report: { Self.report(after, saved.map(\.id)) })
                #expect(after.windows.controllers.count == saved.count, "\(Self.report(after, saved.map(\.id)))")
                for window in saved {
                    let controller = try #require(after.windows.controller(for: window.id), "window \(window.id) did not come back")
                    let shown = try #require(controller.window)
                    #expect(shown.frame == window.frame, "window \(window.id) frame \(shown.frame), saved \(window.frame)")
                    #expect(controller.state.workspaceID == window.workspace, "window \(window.id) shows another workspace")
                    #expect(controller.state.profileID == window.profile, "window \(window.id) is on space \(controller.state.profileID), saved \(window.profile)")
                    #expect(controller.state.sidebarHidden == window.sidebarHidden, "window \(window.id) sidebar hidden \(controller.state.sidebarHidden)")
                    if let width = window.sidebarWidth { #expect(controller.state.sidebarWidth == width, "window \(window.id) sidebar width") }
                    let tabs = controller.workspaceContent?.panes.values.flatMap { $0.pane.tabs.map { "\($0.kind)" } }.sorted() ?? []
                    #expect(tabs == window.tabKinds, "window \(window.id) tabs \(tabs), saved \(window.tabKinds)")
                }
                #expect(after.windows.registry.value.recency.first == front, "the front window is \(String(describing: after.windows.registry.value.recency.first)), was \(front)")
                #expect(Self.unsettledPanes(after).isEmpty, "\(Self.unsettledPanes(after))")
            }
            await Self.quit(after, endingDaemon: true)
            try restored.get()
        }
    }

    /// Launch piece 7 (cmuxterm-hq docs/design/launch-shell-first.md, stage 1: only what is visible): a relaunch with
    /// 60 workspaces in 3 windows makes the views of one workspace, the front window's, by the end of restore; the
    /// other two windows come back after the front window's frame, one per turn, and no other workspace gets views.
    /// Selecting another workspace makes its views once: switching back and forth keeps both (parked, not made again).
    @Test func aRelaunchMakesViewsOnlyForTheFrontWindowsWorkspace() async throws {
        try await Self.withDaemon { launcher in
            let before = try await Self.launch(launcher)
            var front = ""
            var others: [String] = []
            let seeded = await Self.capture {
                let first = try #require(before.windows.active)
                front = first.state.id
                for _ in 0..<2 {
                    let id = UUID().uuidString.lowercased()
                    _ = try #require(await before.windows.createWorkspace(into: id))
                    try await Self.until({ before.windows.controller(for: id)?.workspaceContent != nil }, report: { Self.report(before, [id]) })
                    others.append(id)
                }
                // 60 in all: the launch's workspace, one per other window and 57 more in the front window.
                for _ in 0..<57 { _ = try #require(await before.windows.createWorkspace(into: front)) }
                try await Self.until({ before.daemon.store.workspaces.count >= 60 }, within: .seconds(120),
                                     report: { "workspaces \(before.daemon.store.workspaces.count)" })
                try #require(first.window).makeKeyAndOrderFront(nil)
                before.windows.didActivate(first)
                await before.windows.prepareForTermination()
            }
            await Self.quit(before, endingDaemon: (try? seeded.get()) == nil)
            try seeded.get()

            var atRestore: (controllers: Int, made: Int, deferred: Int)?
            let after = try await Self.launch(launcher) { services in
                services.windows.deferredWindows.onStart = { [unowned services] in
                    let windows = services.windows
                    atRestore = (windows.controllers.count, windows.controllers.map { ($0.workspaceContent != nil ? 1 : 0) + $0.parked.count }.reduce(0, +),
                                 others.filter(windows.deferredWindows.contains).count)
                }
            }
            let restored = await Self.capture {
                #expect(after.daemon.store.workspaces.count >= 60)
                let seen = try #require(atRestore, "restore never ended")
                #expect(seen.controllers == 1, "restore made \(seen.controllers) windows before the front one was live")
                #expect(seen.made <= 1, "restore made views for \(seen.made) workspaces before the front window was live")
                #expect(seen.deferred == 2, "\(seen.deferred) windows wait for their turn, expected 2")
                let all = [front] + others
                try await Self.until({ all.allSatisfy { after.windows.controller(for: $0)?.workspaceContent != nil } && after.windows.deferredWindows.isEmpty },
                                     within: .seconds(60), report: { Self.report(after, all) })
                let made = all.map { (after.windows.controller(for: $0)?.parked.count ?? 0) + 1 }.reduce(0, +)
                #expect(made == 3, "views made for \(made) workspaces, one per window expected")
                #expect(after.windows.registry.value.recency.first == front, "the front window is \(String(describing: after.windows.registry.value.recency.first)), was \(front)")

                // Selecting another workspace makes its views once; switching back and forth makes none.
                let window = try #require(after.windows.controller(for: front))
                let shown = try #require(window.state.workspaceID)
                let other = try #require(after.windows.registry.value.window(front)?.workspaceIDs.first { $0 != shown })
                var views: [String: ObjectIdentifier] = [:]
                for target in [other, shown, other, shown] {
                    after.windows.show(workspaceID: target, in: window.state, from: .thisWindow)
                    try await Self.until({ window.workspaceContent?.workspace.id == target }, report: { Self.report(after, [front]) })
                    let view = ObjectIdentifier(try #require(window.workspaceContent))
                    #expect(views[target, default: view] == view, "showing \(target) again made its views again")
                    views[target] = view
                    #expect(window.parked.count == 1, "\(window.parked.count) workspaces parked, only the one shown before expected")
                }
            }
            await Self.quit(after, endingDaemon: true)
            try restored.get()
        }
    }

    /// Leo: "ofc reopening home if they were prev on home is fine" (ask-efe32fe90d); "fresh startup opening home is obv
    /// fine but if it's not first time and the user was on a workspace and a tab, obv just take them there"
    /// (ask-b7aac8d3f9). The person was last on Home, the Chief's workspace, in the front window (alone, or with a
    /// second window behind it that the launch makes after the front one is live): the relaunch's front window shows
    /// Home, and the launch makes no workspace of its own, before or after the windows behind it come back.
    @Test(arguments: [1, 2]) func aRelaunchLastOnHomeReopensHome(windows: Int) async throws {
        try await Self.withDaemon { launcher in
            let before = try await Self.launch(launcher)
            var front = ""
            var homeID = ""
            var listed: Set<String> = []
            let seeded = await Self.capture {
                let first = try #require(before.windows.active)
                front = first.state.id
                let connection = try #require(before.daemon.connection)
                before.home.ensureHomeWorkspace(connection)
                try await Self.until({ before.home.homeWorkspace != nil }, within: .seconds(60), report: { before.home.homeWorkspaceStep })
                homeID = try #require(before.home.homeWorkspace?.id)
                // A workspace of the person's own in the front window, and one in each window behind it.
                _ = try #require(await before.windows.createWorkspace(into: front))
                for _ in 1..<windows {
                    let id = UUID().uuidString.lowercased()
                    _ = try #require(await before.windows.createWorkspace(into: id))
                    try await Self.until({ before.windows.controller(for: id)?.workspaceContent != nil }, report: { Self.report(before, [id]) })
                }
                // The person's last pick: Home, in the front window.
                try #require(first.window).makeKeyAndOrderFront(nil)
                before.windows.didActivate(first)
                before.windows.show(workspaceID: homeID, in: first.state, from: .thisWindow)
                try await Self.until({ first.workspaceContent?.workspace.id == homeID }, report: { Self.report(before, [front]) })
                before.windows.didActivate(first)
                #expect(before.windows.registry.value.recency.first == front)
                listed = Set(before.daemon.store.workspaces.map(\.id))
                await before.windows.prepareForTermination()
            }
            await Self.quit(before, endingDaemon: (try? seeded.get()) == nil)
            try seeded.get()

            let after = try await Self.launch(launcher)
            let restored = await Self.capture {
                if let connection = after.daemon.connection { after.home.ensureHomeWorkspace(connection) } // as the app's Home service does on connect
                @MainActor func wrong() -> String? {
                    let made = after.daemon.store.workspaces.filter { !listed.contains($0.id) }
                    let window = after.windows.controller(for: front)
                    let frontID = after.windows.registry.value.recency.first
                    guard !made.isEmpty || frontID != front || window?.state.workspaceID != homeID || window?.workspaceContent?.workspace.id != homeID else { return nil }
                    return "front \(String(describing: frontID)) (was \(front)), shows \(String(describing: window?.state.workspaceID)) content "
                        + "\(String(describing: window?.workspaceContent?.workspace.id)) (Home \(homeID)), new workspaces "
                        + "\(made.map { "\($0.id) \($0.name) kind \(String(describing: $0.kind))" }), deferred empty \(after.windows.deferredWindows.isEmpty)\n"
                        + Self.report(after, after.windows.registry.value.openRecency)
                }
                // Every saved window back, then a few seconds more (the spare workspace view fills after the last one).
                try await Self.until({ after.windows.deferredWindows.isEmpty && after.windows.controllers.count == windows }, within: .seconds(60),
                                     report: { Self.report(after, after.windows.registry.value.openRecency) })
                let settled = ContinuousClock.now + .seconds(4)
                var seen: String?
                // test-poll: what the launch fronts can change in any later turn; each turn is checked for 4 s
                while seen == nil, ContinuousClock.now < settled {
                    seen = wrong()
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(seen == nil, "the relaunch did not reopen Home: \(seen ?? "")")
            }
            await Self.quit(after, endingDaemon: true)
            try restored.get()
        }
    }

    /// "Closed workspaces reappear after relaunch" (#31514): the person closes the last window (Close
    /// Window), then quits keeping sessions and relaunches. A relaunch restores only what was open at
    /// quit: that window and its workspaces stay closed (still registered, so Reopen Closed Window
    /// brings them back), and the app opens one new window on a new workspace instead.
    @Test func closedLastWindowStaysClosedAfterRelaunch() async throws {
        try await Self.withDaemon { launcher in
            let before = try await Self.launch(launcher)
            var closedID = ""
            var closedWorkspaces: Set<String> = []
            let seeded = await Self.capture {
                let window = try #require(before.windows.active)
                closedID = window.state.id
                _ = try #require(await before.windows.createWorkspace(into: closedID))
                try await Self.until({ (before.windows.registry.value.window(closedID)?.workspaceIDs.count ?? 0) >= 2 },
                                     report: { Self.report(before, [closedID]) })
                closedWorkspaces = Set(try #require(before.windows.registry.value.window(closedID)).workspaceIDs)
                // The person's Close Window (Cmd-Shift-W's window close, the red button).
                #expect(before.registry.perform("closeWindow", invocation: ActionInvocation(origin: .user)))
                try await Self.until({ before.windows.registry.value.window(closedID)?.isOpen == false },
                                     report: { Self.report(before, [closedID]) })
                await before.windows.prepareForTermination()
                let records = await before.daemon.windowState?.document.windows ?? []
                #expect(records.contains { $0.id == closedID && $0.isClosed }, "no closed record for \(closedID): \(records.map(\.id))")
            }
            await Self.quit(before, endingDaemon: (try? seeded.get()) == nil)
            try seeded.get()

            let after = try await Self.launch(launcher)
            let restored = await Self.capture {
                let registry = after.windows.registry.value
                let open = registry.windows.filter(\.isOpen)
                #expect(registry.window(closedID)?.isOpen == false, "the closed window came back: \(Self.report(after, [closedID]))")
                #expect(after.windows.controller(for: closedID) == nil, "the closed window has a controller: \(Self.report(after, [closedID]))")
                #expect(open.count == 1, "open windows \(open.map(\.id))")
                let shown = Set(open.flatMap(\.workspaceIDs))
                #expect(shown.isDisjoint(with: closedWorkspaces), "closed workspaces shown again: \(shown.intersection(closedWorkspaces))")
                #expect(Set(registry.window(closedID)?.workspaceIDs ?? []) == closedWorkspaces, "the closed window lost its workspaces")
            }
            await Self.quit(after, endingDaemon: true)
            try restored.get()
        }
    }

    /// Shown panes still "Restoring…", disconnected or blank, as `window: pane state`.
    private static func unsettledPanes(_ services: AppServices) -> [String] {
        SurfaceDiagnosticsReport.statuses(services).compactMap { row in
            guard row.status.isVisible else { return nil }
            if row.status.isBlank { return "\(row.window.state.id): \(row.pane.paneKey) blank" }
            if case .terminal(let entry)? = row.pane.currentTabKey.flatMap(row.pane.existingContent(for:)),
               entry.session.model.connection != .connected {
                return "\(row.window.state.id): \(row.pane.paneKey) \(entry.session.model.connection)"
            }
            return nil
        }
    }

    /// The window's pane showing `workspace` once its terminal is connected.
    private static func livePane(_ services: AppServices, window: String, workspace: String) -> PaneController? {
        guard let controller = services.windows.controller(for: window), controller.workspaceContent?.workspace.id == workspace,
              let pane = controller.workspaceContent?.panes.values.first,
              case .terminal(let entry)? = pane.currentTabKey.flatMap(pane.existingContent(for:)),
              entry.session.model.connection == .connected else { return nil }
        return pane
    }

    private static func report(_ services: AppServices, _ ids: [String]) -> String {
        let windows = ids.map { id -> String in
            guard let controller = services.windows.controller(for: id) else {
                return "\(id): no controller, registry \(String(describing: services.windows.registry.value.window(id))), awaiting \(String(describing: services.windows.awaitingContent[id]))"
            }
            return "\(id): visible \(controller.window?.isVisible ?? false) frame \(controller.window?.frame ?? .null) "
                + "state ws \(controller.state.workspaceID ?? "nil") content ws \(controller.workspaceContent?.workspace.id ?? "nil") "
                + "profile \(controller.state.profileID) sidebar hidden \(controller.state.sidebarHidden) width \(controller.state.sidebarWidth)"
        }
        return "controllers \(services.windows.controllers.map(\.state.id)) recency \(services.windows.registry.value.recency)\n"
            + windows.joined(separator: "\n") + "\nunsettled \(unsettledPanes(services))"
    }

    /// Three frames inside the main screen's visible frame, apart from each other.
    private static func frames() -> [CGRect] {
        let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: min(720, visible.width - 160), height: min(460, visible.height - 160))
        return (0..<3).map { index in
            CGRect(x: visible.minX + 30 + CGFloat(index) * 50, y: visible.minY + 30 + CGFloat(index) * 40, width: size.width - CGFloat(index) * 40, height: size.height - CGFloat(index) * 30)
        }
    }

    /// A local page, so the browser tab loads with no network.
    private static func pageFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cn-mw-\(UUID().uuidString.prefix(8)).html")
        try Data("<!doctype html><title>mw</title><p>multi-window restore</p>".utf8).write(to: url)
        return url
    }

    /// The app's services on `launcher`'s daemon, once restore finished and its window shows a pane.
    private static func launch(_ launcher: DaemonLauncher, configure: (AppServices) -> Void = { _ in }) async throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        configure(services)
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        do {
            try await until({ services.windows.restored && !services.windows.restoring && !services.windows.registry.isLaunching
                    && services.daemon.windowState != nil && services.windows.active?.workspaceContent?.panes.isEmpty == false },
                            within: .seconds(90))
        } catch {
            await quit(services, endingDaemon: true)
            throw error
        }
        return services
    }

    /// Ends this launch: its windows and connection, and when `endingDaemon` the daemon with its
    /// terminals (else the next launch reconnects to it, as after Quit and Keep Sessions).
    private static func quit(_ services: AppServices, endingDaemon: Bool) async {
        services.closeWindowsForTest()
        guard let connection = services.daemon.connection else { return }
        services.daemon.shutdownConnection()
        await connection.close()
        if endingDaemon { _ = try? await connection.shutdownDaemon(endTerminals: true) }
    }

    private static func capture(_ body: () async throws -> Void) async -> Result<Void, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private static func withDaemon(_ body: (DaemonLauncher) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-mw-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-mw-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        try await body(launcher)
    }

    private static func until(_ condition: () async throws -> Bool, within timeout: Duration = .seconds(20),
                              report: () async -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        // test-poll: the condition spans AppKit windows and a daemon round trip with no single signal
        while !(try await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let met = try await condition()
        let detail = met ? "" : await report()
        try #require(met, "timed out: \(detail)", sourceLocation: sourceLocation)
    }
}
