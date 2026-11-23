import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// App shortcuts that open content work over a top page, the way Chrome's Cmd-T works over its
/// welcome page. P0 (lead 2026-11-04 00:25Z, STATUS 10364): on a fresh profile the first window
/// showed a first-run top page (Bring your history, #33215, since removed), and the person's New Terminal Tab key (Ctrl-`)
/// made no terminal: 5 of 10 P0 journeys failed at "new_terminal: no new focused terminal pane
/// within 20 s". Every action with targets [.tab] (New Terminal Tab, New Tab, New Browser Tab) was
/// refused over any top page ("This page has no tabs.", TopPages.installTabTargetReasons), and
/// with the workspace parked the handler found no pane either. The keys go through `debug.key`,
/// the journeys' path: the key router, then the registry.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct FirstRunPageAppShortcutsTests {
    /// A top page like the first-run one was, hermetic: a plain view (no Chromium) under the real route
    /// and the real top-page presentation (``TopPages/show(_:services:in:)``).
    private static let pageID = InternalPageID(rawValue: "first-run-keys-test")

    private final class FirstRunPage: InternalPageProvider {
        let page = FirstRunPageAppShortcutsTests.pageID
        let title = "First run"
        let symbol = "sparkles"

        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// Onboarding is off at a plain launch (since 5bef23242326, `AppEnvironment.launchSteps`). These tests
    /// turn it on, as `CMUX_NEXT_ONBOARDING=1` does for a person, so that the first-run page can show.
    private static let onboardingOn = ["CMUX_NEXT_ONBOARDING": "1"]

    private static func showFirstRunPage(_ services: AppServices, _ controller: WindowController) throws {
        services.pages.register(FirstRunPage())
        try #require(TopPages.show(.page(pageID), services: services) != nil, "the first-run page did not show")
        try #require(controller.shownTopPage == .page(pageID), "the first-run page did not show")
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
        try await PasswordManagerRouteTests.withApp(environment: Self.onboardingOn) { services, _ in
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
        try await PasswordManagerRouteTests.withApp(environment: Self.onboardingOn) { services, _ in
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
        try await PasswordManagerRouteTests.withApp(environment: Self.onboardingOn) { services, _ in
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
        try await PasswordManagerRouteTests.withApp(environment: Self.onboardingOn) { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))

            let reply = Self.press("w", ["cmd"], services)
            #expect(services.keyRouter.lastInterception?.ran != true, "Cmd-W ran over the page: \(Self.report(services, controller, reply))")
            #expect(controller.shownTopPage == .page(Self.pageID))
            #expect(Set(PasswordManagerRouteTests.tabs(services).map(\.id)) == before)

            let window = try #require(controller.window)
            for (characters, keyCode) in [("\t", UInt16(48)), ("\r", UInt16(36)), (" ", UInt16(49))] {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                                                          context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                          isARepeat: false, keyCode: keyCode))
                #expect(!services.keyRouter.interceptKeyDown(event, in: window), "the app took key \(keyCode) from the page")
            }
            #expect(controller.shownTopPage == .page(Self.pageID))
        }
    }

    /// A script's New Tab (no target) over the page is refused and changes nothing the person
    /// sees: the page stays and no tab is added to the workspace parked under it (on #34547 the
    /// run went on with no focused pane and filled a tab into that parked workspace).
    @Test func aScriptsNewTabOverTheFirstRunPageIsRefused() async throws {
        try await PasswordManagerRouteTests.withApp(environment: Self.onboardingOn) { services, _ in
            let controller = try #require(services.windows.active)
            try Self.showFirstRunPage(services, controller)
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            var work: [ActionWork] = []
            for origin in [ActionOrigin.script, .cli, .mcp] {
                for id in ["newTab.default", "newSurface"] as [ActionID] {
                    var ran = false
                    work += services.registry.capturingWork { ran = services.registry.perform(id, invocation: ActionInvocation(origin: origin)) }
                    #expect(!ran, "\(origin) \(id) ran over the page")
                }
            }
            // A wrongly started daemon create is work these runs reported: wait for it to end, then for the
            // store to apply every event the daemon sent, before the store is read.
            for task in work { _ = await task.value }
            if let connection = services.daemon.connection, let barrier = await connection.eventSequence() {
                try await PasswordManagerRouteTests.until({ services.daemon.store.appliedSequence >= barrier })
            }
            #expect(controller.shownTopPage == .page(Self.pageID), "automation took the person's page away")
            #expect(Set(PasswordManagerRouteTests.tabs(services).map(\.id)) == before, "automation added a tab under the page")
        }
    }

    /// The actions that open a new tab or pane in the window's workspace (the New Tab family and the
    /// new panes) are exactly the ones the Rust catalog flags (a rename must not drop one silently).
    @Test func everyContentOpenerIsACatalogAction() {
        let openers: Set<ActionID> = [
            "newSurface", "newTab.default", "newTab.afterCurrent", "newTab.atStart", "newTab.atEnd", "newTab.toRight", "newTab.ofKind",
            "openBrowser", "openBrowser.chromium", "openBrowser.webkit", "reopenClosedBrowserPanel",
            "splitRight", "splitDown", "newColumn", "newColumnLeft", "newRow", "newPaneAutoLayout",
        ]
        // The floating pane rows can be in the catalog before the App code that runs them (`FloatingPanePlaceholders`):
        // such a row opens nothing yet, so it is not in this set. The change that binds their handlers puts each of
        // them that opens content into `openers` and takes the subtraction out.
        let flagged = Set(ActionCatalog.all.filter(\.opensWorkspaceContent).map(\.id)).subtracting(FloatingPanePlaceholders.ids)
        #expect(flagged == openers, "missing: \(openers.subtracting(flagged)), extra: \(flagged.subtracting(openers))")
    }
}
