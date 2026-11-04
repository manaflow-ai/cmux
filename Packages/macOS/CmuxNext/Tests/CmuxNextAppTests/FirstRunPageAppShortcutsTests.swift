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
