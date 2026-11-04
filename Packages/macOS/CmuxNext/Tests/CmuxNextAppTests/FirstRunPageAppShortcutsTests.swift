import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextSettings
import Foundation
import Testing

/// App shortcuts that open content work over a top page, the way Chrome's Cmd-T works over its
/// welcome page. P0 (lead 2026-11-04 00:25Z, STATUS 10364): on a fresh profile the first window
/// shows Bring your history (#33215) as a top page, and the person's New Terminal Tab key (Ctrl-`)
/// made no terminal: 5 of 10 P0 journeys failed at "new_terminal: no new focused terminal pane
/// within 20 s". Every action with targets [.tab] (New Terminal Tab, New Tab, New Browser Tab) was
/// refused over any top page ("This page has no tabs.", TopPages.installTabTargetReasons), and
/// with the workspace parked the handler found no pane either. The keys go through `debug.key`,
/// the journeys' path: the key router, then the registry.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct FirstRunPageAppShortcutsTests {
    /// The first-run page, hermetic: a plain view (no Chromium) under the real route and the real
    /// first-run presentation (`OnboardingService.showHistoryAtFirstRun`).
    private final class FirstRunPage: InternalPageProvider {
        let page = InternalPageID.importHistory
        let title = "Bring your history"
        let symbol = "square.and.arrow.down"

        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    private static func showFirstRunPage(_ services: AppServices, _ controller: WindowController) throws {
        let suite = "cmux-first-run-keys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        services.pages.register(FirstRunPage())
        services.onboarding.showHistoryAtFirstRun(isFirstRun: true, defaults: defaults)
        try #require(controller.shownTopPage == .page(.importHistory), "the first-run page did not show")
    }

    private static func press(_ key: String, _ modifiers: [String], _ services: AppServices) -> CmuxNextSettings.JSONValue {
        DebugKey.send(["key": .string(key), "modifiers": .array(modifiers.map { .string($0) })], services: services)
    }

    private static func report(_ services: AppServices, _ controller: WindowController, _ reply: CmuxNextSettings.JSONValue) -> String {
        let last = services.keyRouter.lastInterception
        return "page \(String(describing: controller.shownTopPage)), focus \(controller.focus.state.resolved), "
            + "router \(last.map { "\($0.action.rawValue) ran \($0.ran)" } ?? "nothing"), debug.key \(reply)"
    }

    /// Ctrl-` over the page: New Terminal Tab runs, the window leaves the page for its workspace,
    /// and a new terminal has the focus (what the journeys' `new_terminal` step waits for).
    @Test func newTerminalKeyOverTheFirstRunPageMakesAFocusedTerminal() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))

            let reply = Self.press("`", ["control"], services)
            #expect(services.keyRouter.lastInterception?.action == "newSurface")
            #expect(services.keyRouter.lastInterception?.ran == true, "New Terminal Tab was refused: \(Self.report(services, controller, reply))")
            try await PasswordManagerRouteTests.until({
                guard controller.shownTopPage == nil, case .terminal(_, let tab) = controller.focus.state.resolved else { return false }
                return !before.contains(tab) && !ProvisionalTab.isProvisional(tab)
            }, report: { Self.report(services, controller, reply) })
            #expect(PasswordManagerRouteTests.tabs(services).contains { !before.contains($0.id) && $0.kind == .pty })
        }
    }

    /// The action budget sees the leave: the `newSurface` run that Ctrl-` starts over the page is
    /// timed from before the window leaves the page (ActionBudgetMonitor, < 10 ms to the commit).
    @Test func theNewTerminalKeysTimingIncludesTheLeave() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            @MainActor final class Seen { var sample: ActionTimingSample?; var leftAt: UInt64? }
            let seen = Seen()
            let previous = controller.root.onContentChange
            controller.root.onContentChange = { if seen.leftAt == nil { seen.leftAt = ActionBudgetMonitor.now() }; previous?() }
            defer { controller.root.onContentChange = previous }
            let stream = services.actionBudget.samples(everyRun: true)
            let reader = Task { @MainActor in
                for await sample in stream where sample.id == "newSurface" { seen.sample = sample; break }
            }
            defer { reader.cancel() }

            let reply = Self.press("`", ["control"], services)
            try await PasswordManagerRouteTests.until({ seen.sample != nil && seen.leftAt != nil },
                                                      report: { "sample \(String(describing: seen.sample)), left \(String(describing: seen.leftAt)), \(Self.report(services, controller, reply))" })
            let sample = try #require(seen.sample), leftAt = try #require(seen.leftAt)
            #expect(sample.startUptimeNanos <= leftAt, "the run's timing started \(Double(sample.startUptimeNanos) - Double(leftAt)) ns after the leave")
        }
    }

    /// A stale workspace id (a workspace that closed or moved while the page showed) must not make
    /// the window refuse Ctrl-`: leaving the page shows the window's first listed workspace, as
    /// `showWorkspace` does, so `leavingShowsWorkspace` must say so and the key must still make a
    /// focused terminal (review of #35092, note a).
    @Test func newTerminalKeyOverThePageWithAStaleWorkspaceIDStillMakesATerminal() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            controller.state.workspaceID = "workspace-that-is-gone-\(UUID().uuidString)"
            #expect(controller.leavingShowsWorkspace, "a stale id hides the workspace showWorkspace falls back to")
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))

            let reply = Self.press("`", ["control"], services)
            #expect(services.keyRouter.lastInterception?.ran == true, "New Terminal Tab was refused: \(Self.report(services, controller, reply))")
            try await PasswordManagerRouteTests.until({
                guard controller.shownTopPage == nil, case .terminal(_, let tab) = controller.focus.state.resolved else { return false }
                return !before.contains(tab) && !ProvisionalTab.isProvisional(tab)
            }, report: { Self.report(services, controller, reply) })
        }
    }

    /// Leaving the page shows a waiting view, not a pane, in two cases where the window's id is
    /// stale: its Cloud machine is paused (the paused machine's view), or a create of that workspace
    /// returned before the store listed it (the connecting view). Ctrl-` is then refused and the page
    /// stays: a leave would lose the key (the handler finds no pane). Lead 2026-11-04 on #35168.
    @Test(arguments: ["paused Cloud machine", "create not listed yet"])
    func newTerminalKeyOverThePageWhereTheLeaveShowsAWaitingViewKeepsThePage(_ waiting: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            let stale = "workspace-not-here-\(UUID().uuidString)"
            if waiting == "paused Cloud machine" {
                let session = MachineIconTests.cloudMachine(services, id: "vm-page-\(UUID().uuidString.prefix(8))")
                session.machine.status = .paused
                controller.state.machineID = session.machineID
            } else {
                services.windows.claims.pending[stale] = controller.state.id
            }
            controller.state.workspaceID = stale
            #expect(!controller.leavingShowsWorkspace, "\(waiting): leaving shows a waiting view, not a pane")
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))

            let reply = Self.press("`", ["control"], services)
            #expect(services.keyRouter.lastInterception?.ran != true, "\(waiting): Ctrl-` ran: \(Self.report(services, controller, reply))")
            #expect(controller.shownTopPage == .page(.importHistory), "\(waiting): the page was left for a waiting view")
            #expect(Set(PasswordManagerRouteTests.tabs(services).map(\.id)) == before)
        }
    }

    /// The class, not one key: New Tab (Cmd-T) over the page opens a tab in the workspace too.
    @Test func newTabKeyOverTheFirstRunPageOpensATab() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))

            let reply = Self.press("t", ["cmd"], services)
            #expect(services.keyRouter.lastInterception?.action == "newTab.default")
            #expect(services.keyRouter.lastInterception?.ran == true, "New Tab was refused: \(Self.report(services, controller, reply))")
            try await PasswordManagerRouteTests.until({
                controller.shownTopPage == nil
                    && PasswordManagerRouteTests.tabs(services).contains { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }
            }, report: { Self.report(services, controller, reply) })
        }
    }

    /// What does not change: an action on an existing tab (Cmd-W) is still refused over the page
    /// (pages have no tabs), the page stays, and the page's own keys (Tab, Return, Space) are not
    /// taken by the app.
    @Test func closeTabStaysRefusedAndThePageKeepsItsKeys() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))

            let reply = Self.press("w", ["cmd"], services)
            #expect(services.keyRouter.lastInterception?.ran != true, "Cmd-W ran over the page: \(Self.report(services, controller, reply))")
            #expect(controller.shownTopPage == .page(.importHistory))
            #expect(Set(PasswordManagerRouteTests.tabs(services).map(\.id)) == before)

            let window = try #require(controller.window)
            for (characters, keyCode) in [("\t", UInt16(48)), ("\r", UInt16(36)), (" ", UInt16(49))] {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                                                          context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                          isARepeat: false, keyCode: keyCode))
                #expect(!services.keyRouter.interceptKeyDown(event, in: window), "the app took key \(keyCode) from the page")
            }
            #expect(controller.shownTopPage == .page(.importHistory))
        }
    }

    /// A script's New Tab (no target) over the page is refused and changes nothing the person
    /// sees: the page stays and no tab is added to the workspace parked under it (on #34547 the
    /// run went on with no focused pane and filled a tab into that parked workspace).
    @Test func aScriptsNewTabOverTheFirstRunPageIsRefused() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            for origin in [ActionOrigin.script, .cli, .mcp] {
                for id in ["newTab.default", "newSurface"] as [ActionID] {
                    #expect(!services.registry.perform(id, invocation: ActionInvocation(origin: origin)), "\(origin) \(id) ran over the page")
                }
            }
            // Give a wrongly started daemon create the time to land before the store is read.
            try await Task.sleep(for: .seconds(2))
            #expect(controller.shownTopPage == .page(.importHistory), "automation took the person's page away")
            #expect(Set(PasswordManagerRouteTests.tabs(services).map(\.id)) == before, "automation added a tab under the page")
        }
    }

    /// Every action the rule names exists in the catalog and carries the flag (a rename must not drop one silently).
    @Test func everyContentOpenerIsACatalogAction() {
        let flagged = Set(ActionCatalog.all.filter(\.opensWorkspaceContent).map(\.id))
        #expect(flagged == ActionCatalog.workspaceContentActionIDs, "missing: \(ActionCatalog.workspaceContentActionIDs.subtracting(flagged))")
    }
}
