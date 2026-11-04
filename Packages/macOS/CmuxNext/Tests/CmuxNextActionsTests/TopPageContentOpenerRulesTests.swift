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
        /// Classic Home: leaving shows the Home page again in place of the hidden home workspace.
        var staysAfterLeave = false
        var leaves = 0
    }

    static func registry(_ page: Page) -> (ActionRegistry, ran: () -> [ActionID]) {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var ran: [ActionID] = []
        for id in ["newTab.default", "newSurface", "splitRight", "closeTab"] as [ActionID] {
            registry.bind(id, invoke: { _ in ran.append(id) })
        }
        registry.install(ActionTopPageRules(isShowing: { page.shown },
                                            leave: { page.leaves += 1; if !page.staysAfterLeave { page.shown = false } },
                                            noTabs: { "This page has no tabs." }))
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
