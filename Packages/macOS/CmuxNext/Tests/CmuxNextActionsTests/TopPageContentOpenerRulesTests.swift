import AppKit
@testable import CmuxNextActions
import Testing

/// Over a top page, a person's New Tab, New Terminal Tab or split leaves the page and runs in the
/// window's workspace (#34547). Two runs must not: automation (a script's, an agent's or the CLI's
/// New Tab with no target, refused on feat before #34547) never changes what the person sees, and
/// a leave that shows no workspace (classic Home stands for the hidden home workspace, so the
/// page shows again) must not run the handler into a workspace nobody sees.
@MainActor
struct TopPageContentOpenerRulesTests {
    final class Page {
        var shown = true
        /// Whether the action's timing was open when the page was left (the leave is part of the run).
        var leftInsideTiming: [Bool] = []
        /// Classic Home: leaving shows the Home page again in place of the hidden home workspace.
        var staysAfterLeave = false
        var leaves = 0
    }

    /// Times runs and says whether one is being timed now.
    @MainActor final class Timing: ActionRunTiming {
        var timed: [ActionID] = []
        private(set) var isTiming = false
        func intern(_ id: ActionID) -> UInt32 { 0 }
        func time<T>(_ key: ActionRunKey, _ origin: ActionOrigin, input: () -> ActionRunInput, _ body: () -> T) -> T {
            timed.append(key.id)
            isTiming = true
            defer { isTiming = false }
            return body()
        }
        func beginGate(_ id: ActionID, _ origin: ActionOrigin, input: () -> ActionRunInput) -> (@MainActor () -> Void)? { nil }
    }

    static func registry(_ page: Page, timing: Timing = Timing()) -> (ActionRegistry, ran: () -> [ActionID]) {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases, runTiming: timing)
        registry.context = ActionContext(rawValue: .max)
        var ran: [ActionID] = []
        for id in ["newTab.default", "newSurface", "splitRight", "closeTab"] as [ActionID] {
            registry.bind(id, invoke: { _ in ran.append(id) })
        }
        registry.install(ActionTopPageRules(isShowing: { page.shown }, canLeave: { !page.staysAfterLeave },
                                            leave: {
                                                page.leaves += 1
                                                page.leftInsideTiming.append(timing.isTiming)
                                                if !page.staysAfterLeave { page.shown = false }
                                            },
                                            noTabs: { "This page has no tabs." }, noPanes: { "This page has no panes." }))
        return (registry, { ran })
    }

    @Test func aPersonsNewTabLeavesThePageAndRuns() {
        let page = Page()
        let (registry, ran) = Self.registry(page)
        #expect(registry.perform("newTab.default", invocation: ActionInvocation()))
        #expect(page.leaves == 1 && !page.shown)
        #expect(ran() == ["newTab.default"])
    }

    @Test func automationsNewTabOverAPageIsRefusedAndThePageStays() {
        for origin in [ActionOrigin.cli, .mcp, .script, .page, .remote] {
            for id in ["newTab.default", "newSurface", "splitRight"] as [ActionID] {
                let page = Page()
                let (registry, ran) = Self.registry(page)
                #expect(!registry.perform(id, invocation: ActionInvocation(origin: origin)), "\(origin) \(id) ran over the page")
                #expect(page.shown && page.leaves == 0, "\(origin) \(id) took the person's page away")
                #expect(ran().isEmpty, "\(origin) \(id) ran its handler over the page")
                #expect(ActionTargetReasons.reason(for: id, invocation: ActionInvocation(origin: origin), in: registry) != nil)
            }
        }
        // A person's invocation nested in a CLI run is the CLI's.
        let page = Page()
        let (registry, ran) = Self.registry(page)
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: true)) {
            #expect(!registry.perform("newTab.default", invocation: ActionInvocation()))
        }
        #expect(page.shown && ran().isEmpty)
        // A person's invocation in a scope that may not change the view (a carried scope) is refused too.
        let quiet = Page()
        let (quietRegistry, quietRan) = Self.registry(quiet)
        ActionRunScope.$current.withValue(ActionRunScope(origin: .user, allowsViewChange: false)) {
            #expect(!quietRegistry.perform("newTab.default", invocation: ActionInvocation()))
        }
        #expect(quiet.shown && quiet.leaves == 0 && quietRan().isEmpty)
    }

    @Test func automationWithATargetStillRuns() {
        let page = Page()
        let (registry, ran) = Self.registry(page)
        let named = ActionInvocation(target: ActionTargetRef(kind: .pane, id: "pane-1"), origin: .script)
        #expect(registry.perform("newTab.default", invocation: named))
        #expect(page.shown && page.leaves == 0, "a run that names its pane never touches the page")
        #expect(ran() == ["newTab.default"])
    }

    @Test func aLeaveThatShowsNoWorkspaceRunsNothing() {
        let page = Page()
        page.staysAfterLeave = true
        let (registry, ran) = Self.registry(page)
        #expect(!registry.perform("newTab.default", invocation: ActionInvocation()))
        #expect(ran().isEmpty, "Cmd-T over classic Home ran into the hidden home workspace")
        // Refused with no window change, as on feat before #34547: History does not turn into Home first.
        #expect(page.leaves == 0 && page.shown, "the window changed before the refusal")
        #expect(ActionTargetReasons.reason(for: "newTab.default", invocation: ActionInvocation(), in: registry) != nil,
                "a menu would offer New Tab where it cannot run")
    }

    /// The person's Ctrl-` over a page: the action's timing (`action.perform`, the action budget's
    /// < 10 ms to the commit) starts before the page is left, so the workspace swap is counted.
    @Test func aPersonsLeaveRunsInsideTheActionsTiming() {
        for id in ["newSurface", "newTab.default", "splitRight"] as [ActionID] {
            let page = Page()
            let timing = Timing()
            let (registry, ran) = Self.registry(page, timing: timing)
            #expect(registry.perform(id, invocation: ActionInvocation()))
            #expect(page.leftInsideTiming == [true], "\(id): the leave ran outside the action's timing")
            #expect(timing.timed == [id] && ran() == [id])
        }
    }

    /// A refused New Tab or split says what is missing: a page has no panes. "This page has no tabs."
    /// stays for the actions on an existing tab.
    @Test func aRefusedOpenerSaysThePageHasNoPanes() {
        let page = Page()
        let (registry, _) = Self.registry(page)
        let script = ActionInvocation(origin: .script)
        for id in ["newSurface", "newTab.default", "splitRight"] as [ActionID] {
            #expect(ActionTargetReasons.reason(for: id, invocation: script, in: registry) == "This page has no panes.")
        }
        #expect(ActionTargetReasons.reason(for: "closeTab", invocation: script, in: registry) == "This page has no tabs.")
    }

    @Test func closeTabStaysRefusedForEveryone() {
        for origin in [ActionOrigin.user, .cli, .script] {
            let page = Page()
            let (registry, ran) = Self.registry(page)
            #expect(!registry.perform("closeTab", invocation: ActionInvocation(origin: origin)))
            #expect(page.shown && ran().isEmpty)
        }
    }
}
