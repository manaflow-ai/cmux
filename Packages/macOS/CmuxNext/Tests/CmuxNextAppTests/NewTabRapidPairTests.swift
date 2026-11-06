import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Lead decision on #32979 (a rapid second Cmd-T must not load cold): two Cmd-T in quick succession both adopt a page
/// that is already loaded, as Chrome keeps a spare renderer ready for the next navigation; and the pool makes no page
/// in the opens' frames.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabRapidPairTests {
    /// The pool with two inert spares parked (they stand in for WebKit's pages; `painted` says which count as drawn).
    final class Rig {
        var made: [AgentPaneView] = []
    }

    /// The pool keeps two spares, which it fills only after one served an open: the rig hands out the launch's spare
    /// first. `painted(n)` / `framed(n)`: the n-th spare parked after that counts as drawn / reports its frames in a pane.
    static func filledPool(_ services: AppServices, window: NSWindow, folder: URL, painted: @escaping (Int) -> Bool = { _ in true },
                           framed: @escaping (Int) -> Bool = { _ in true }) async throws -> Rig {
        let html = folder.appending(path: "index.html")
        try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
        let pool = services.newTabSpares, rig = Rig()
        pool.dropAll()
        pool.capacity = 2
        pool.makeSpare = { page in
            let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
            guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
            let parked = rig.made.count - 1 // made[0] is the launch's spare, handed out below
            if parked < 0 || painted(parked) {
                model.hasHandshake = true
                model.markPainted()
            }
            let reports = parked < 0 || framed(parked)
            view.redraw.nextFrameOverride = { body in if reports { body() } }
            rig.made.append(view)
            return view
        }
        pool.retarget(window)
        pool.prewarm()
        pool.start()
        try await PasswordManagerRouteTests.until({ rig.made.count == 1 && pool.spare != nil }, within: .seconds(5), report: { "\(rig.made.count) spares made" })
        let launch = try #require(pool.take(for: window, size: nil)?.view)
        launch.removeFromSuperview()
        try await PasswordManagerRouteTests.until({ rig.made.count == 3 && pool.spare != nil }, within: .seconds(5), report: { "\(rig.made.count - 1) spares made after the handout" })
        return rig
    }

    static func cleanUp(_ services: AppServices, _ rig: Rig?, _ folder: URL) {
        services.newTabSpares.makeSpare = nil
        services.newTabSpares.dropAll()
        rig?.made.forEach { $0.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rapid-pair-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Two Cmd-T `gap` apart: every opening of the pair adopts a spare, and none is made from the first key until 60 ms
    /// after the second.
    func pair(gap: Duration, id: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: id)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try Self.folder()
            var rig: Rig?
            defer { Self.cleanUp(services, rig, folder) }
            rig = try await Self.filledPool(services, window: window, folder: folder)
            let pool = services.newTabSpares, before = rig?.made.count ?? 0, openings = pool.openings.count

            NewTabPage.open(in: pane, seed: nil)
            try await Task.sleep(for: gap)
            NewTabPage.open(in: pane, seed: nil)
            try await Task.sleep(for: .milliseconds(60))

            // A cold open records a second opening (the store's tab takes no spare either): every one must be a spare.
            let pair = pool.openings.dropFirst(openings).map(\.spare)
            #expect(pair.count >= 2 && !pair.contains(false), "a Cmd-T \(gap) after the one before loaded cold (spare per opening: \(pair))")
            #expect(rig?.made.count == before, "a spare was made within the pair's frames (\((rig?.made.count ?? 0) - before) made)")
            // The pool fills again after the pair; memory pressure's drop leaves no spare.
            try await PasswordManagerRouteTests.until({ (rig?.made.count ?? 0) >= before + 2 }, within: .seconds(5),
                                                      report: { "\((rig?.made.count ?? 0) - before) spares made after the pair" })
            let refilled = rig?.made.suffix(2) ?? []
            pool.dropAll()
            #expect(pool.spare == nil && refilled.allSatisfy { $0.superview == nil }, "a spare stayed parked after dropAll")
        }
    }

    @Test func aRapidSecondCmdTAdoptsASpareToo() async throws {
        try await pair(gap: .milliseconds(150), id: "cn-rapid-pair")
    }

    /// A handout while an earlier open's refill waits restarts the wait: the second open's page has not reported its
    /// frame yet, so nothing may be made in the 500 ms after it (the first open's 250 ms wait would land there).
    @Test func aSecondCmdTRestartsTheFirstOnesRefill() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-rapid-pair-restart")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try Self.folder()
            var rig: Rig?
            defer { Self.cleanUp(services, rig, folder) }
            rig = try await Self.filledPool(services, window: window, folder: folder, framed: { $0 == 0 })
            let before = rig?.made.count ?? 0
            NewTabPage.open(in: pane, seed: nil)
            try await Task.sleep(for: .milliseconds(150))
            NewTabPage.open(in: pane, seed: nil)
            try await Task.sleep(for: .milliseconds(500))
            #expect(rig?.made.count == before, "the first open's refill made a spare during the second open (\((rig?.made.count ?? 0) - before) made)")
        }
    }

    /// A parked spare that has not painted yet does not hold the other one's context: the next spare handed out draws
    /// the context a Cmd-T in its window gives.
    @Test func anUnpaintedSecondSpareDoesNotHoldTheFirstsContext() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-rapid-pair-context")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            try await PasswordManagerRouteTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            window.orderFrontRegardless()
            let folder = try Self.folder()
            var rig: Rig?
            defer { Self.cleanUp(services, rig, folder) }
            // Both spares are parked first (the second never paints); then the window's context changes.
            rig = try await Self.filledPool(services, window: window, folder: folder, painted: { $0 == 0 })
            let pool = services.newTabSpares
            let first = try #require(pool.spare?.view)
            #expect(first === rig?.made.dropFirst().first)
            let workspace = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: folder.path, name: "rapid-pair", command: "/bin/sh"),
                                                                       into: controller.state.id)
            services.windows.show(workspaceID: workspace, in: controller.state)
            @MainActor func terminalPane() -> PaneController? { controller.content?.panes.values.first { $0.selectedTab?.kind == .pty } }
            @MainActor func keyPage() -> AgentPaneNewTab? {
                controller.content?.focusedPane.map { NewTabPage.page(services, selected: $0.selectedTab, window: window, pane: $0, paletteActions: false) }
            }
            try await PasswordManagerRouteTests.until({
                guard controller.state.workspaceID == workspace, let pane = terminalPane() else { return false }
                if controller.content?.focusedPane !== pane { controller.focus.send(.focusPane(pane.paneKey, source: .intent)) }
                return controller.content?.focusedPane === pane && keyPage()?.cwd != nil
            }, report: { "the workspace's terminal never had the focus and a folder" })
            pool.paneLayoutDidChange(in: window)
            let want = try #require(keyPage())
            try await PasswordManagerRouteTests.until({
                NewTabSpareContextTests.screen(first.model.newTab) == NewTabSpareContextTests.screen(want) && first.model.newTabPrepared
            }, within: .seconds(3), report: { "the first spare draws cwd \(first.model.newTab?.cwd ?? "nil"), Cmd-T gives \(want.cwd ?? "nil")" })
        }
    }

    /// A launch loads one page, as before two spares: the second is made only after a spare served an open, so its load
    /// never meets the session's first open.
    @Test func aLaunchMakesOneSpareUntilOneServedAnOpen() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-rapid-pair-launch")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try Self.folder()
            let rig = Rig()
            defer { Self.cleanUp(services, rig, folder) }
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            let pool = services.newTabSpares
            pool.dropAll()
            pool.capacity = 2
            pool.makeSpare = { page in
                let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
                guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
                model.hasHandshake = true
                model.markPainted()
                rig.made.append(view)
                return view
            }
            pool.retarget(window)
            pool.prewarm()
            pool.start()
            try await PasswordManagerRouteTests.until({ !rig.made.isEmpty }, within: .seconds(5), report: { "no spare was made" })
            // The person clicks another window first (a restored multi-window launch): the pool follows it, still one page.
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            pool.retarget(other)
            // Past the quiet-input warm (750 ms) with no input: still one page.
            try await Task.sleep(for: .seconds(2))
            #expect(rig.made.count == 1, "the launch made \(rig.made.count) spares before any open")
            pool.retarget(window)
            NewTabPage.open(in: pane, seed: nil)
            try await PasswordManagerRouteTests.until({ rig.made.count >= 3 }, within: .seconds(5), report: { "\(rig.made.count - 1) spares after the first open" })
        }
    }
}
