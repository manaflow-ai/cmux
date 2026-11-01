import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-10-20: "when you open up a new tab ... if you came from a split workspace pane session,
/// then it goes, like, the layout shifts and splits." Since 2026-10-19 what a New Tab page opened
/// beside another tab (a terminal, a browser, a chat card) went through ``LinkOpener``: to the pane
/// on the right, else a new split, and the page's pane fell back to its old tab. The New Tab page
/// is the tab the person opened in this pane: its pick takes the page's place there, whatever
/// `layout.linkPlacement` says, and no pane or divider moves. The Debug toggle `newTab.picksFollowLinks`
/// opts back into the link rule (Lawrence 2026-10-19). Serialized: the toggle is the shared store's.
@MainActor @Suite(.serialized) struct NewTabPagePickInPlaceTests {
    /// A pane holding a terminal (surface 1) and the New Tab page (surface 2), or the page alone, with
    /// the Debug toggle `newTab.picksFollowLinks` on (`optedIn`) or at its default.
    private static func pane(withTerminal: Bool, optedIn: Bool = false) throws -> (AppServices, PaneController, String) {
        _ = NSApplication.shared
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        _ = store.set(AgentPaneTunables.newTabPicksFollowLinks.key, optedIn ? .bool(true) : nil)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let surfaces: [UInt64] = withTerminal ? [1, 2] : [2]
        let snapshot = PaneSnapshot(id: PaneID(rawValue: 1), tabs: surfaces.map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [snapshot])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let page = try #require(services.daemon.store.tab(surface: SurfaceID(rawValue: 2))).id
        services.agentTabs.newTabPages[page] = (AgentPaneNewTab(kind: .agent), NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        return (services, pane, page)
    }

    /// Runs the page's terminal pick and reports whether it asked where links go (a pick routed
    /// through ``LinkOpener`` reads `layout.linkPlacement` to find the pane on the right or split).
    private static func pickConsultsLinkPlacement(_ placement: LinkPlacement, withTerminal: Bool, optedIn: Bool = false) throws -> Bool {
        let (services, pane, page) = try Self.pane(withTerminal: withTerminal, optedIn: optedIn)
        defer {
            pane.teardown()
            _ = TunableStore.shared.set(AgentPaneTunables.newTabPicksFollowLinks.key, nil)
        }
        var consulted = false
        services.linkOpener.placement = {
            consulted = true
            return placement
        }
        NewTabPage.replace(page, with: AgentPaneOpenTab(kind: .terminal, text: "", run: false), cwd: nil, in: pane)
        return consulted
    }

    @Test func aPickOnANewTabPageBesideAnotherTabTakesThePagesPlace() throws {
        #expect(try !Self.pickConsultsLinkPlacement(.splitRight, withTerminal: true),
                "the page's pick went to the pane on the right or a new split instead of the page's tab")
        #expect(try !Self.pickConsultsLinkPlacement(.newColumn, withTerminal: true),
                "the page's pick went to a new column instead of the page's tab")
    }

    /// Nothing else in the pane: the page becomes what it opened, as it always did.
    @Test func aLonePageIsReplacedInPlace() throws {
        #expect(try !Self.pickConsultsLinkPlacement(.splitRight, withTerminal: false))
    }

    /// The Debug toggle is off unless someone turns it on.
    @Test func followingLinksIsOptIn() {
        #expect(!AgentPaneTunables.newTabPicksFollowLinks.defaultValue)
    }

    @Test(arguments: AgentPaneTabKind.allCases) func refusedNativePairingLinkDoesNotAcceptTheSubmission(kind: AgentPaneTabKind) throws {
        let (services, pane, page) = try Self.pane(withTerminal: false)
        defer { pane.teardown() }
        var consultedPlacement = false
        services.linkOpener.placement = { consultedPlacement = true; return .splitRight }
        let accepted = NewTabPage.submitNative("cmux-vnc://pair?room=test&secret=synthetic", kind: kind,
                                               search: true, cwd: nil, in: pane)
        #expect(!accepted, "nativeActions must leave the page open when the submission is refused")
        #expect(!consultedPlacement)
        #expect(services.agentTabs.newTabPages[page] != nil)
    }

    @Test(arguments: [false, true]) func nativeTerminalRunAndBrowserCommandKeepDifferentInput(search: Bool) throws {
        let resolver = OmniboxResolver()
        let run = try #require(NewTabSubmit.nativeRequest(text: "  echo hello  ", kind: .terminal, search: search,
                                                         cwd: "/project", resolver: resolver))
        let typed = try #require(NewTabSubmit.nativeRequest(text: " !echo hello ", kind: .browser, search: search,
                                                           cwd: "/project", resolver: resolver))
        #expect(run.kind == .terminal && run.run)
        #expect(typed.kind == .terminal && !typed.run)
        #expect(NewTabPage.nativeTerminalTyping(run) == "echo hello\n")
        #expect(NewTabPage.nativeTerminalTyping(typed) == "echo hello")
        #expect(run.cwd == "/project" && typed.cwd == "/project")
        for request in [run, typed] {
            #expect(LinkOpenPlacement<String>.inColumn(right: "web", column: ["web"], sourceWidth: 1400,
                                                       width: { _ in 700 }, kind: request.kind.rightColumnKind,
                                                       holds: { _, kind in kind == .browser }) == .splitBelow(of: "web"),
                    "both terminal intents go below an existing browser in the chat's right column")
        }
        for kind in [AgentPaneTabKind.terminal, .browser] {
            let empty = try #require(NewTabSubmit.nativeRequest(text: kind == .terminal ? " " : "!", kind: kind,
                                                               search: search, cwd: nil, resolver: resolver))
            #expect(NewTabPage.nativeTerminalTyping(empty) == nil)
        }
    }

    @Test(arguments: ["readme.md", "node.js", "find the latest release"], [false, true])
    func nativeBrowserWordsAndFileNamesSearchInEitherPlacement(text: String, search: Bool) throws {
        let (services, pane, _) = try Self.pane(withTerminal: false)
        defer { pane.teardown() }
        let resolver = services.cache.suggestionEngine.resolver
        let request = try #require(NewTabSubmit.nativeRequest(text: text, kind: .browser, search: search,
                                                             cwd: nil, resolver: resolver))
        let expected = try #require(resolver.searchEngine.searchURL(for: text))
        #expect(request.kind == .browser)
        #expect(LinkOpenPlacement<String>.inColumn(right: "web", column: ["web"], sourceWidth: 1400,
                                                   width: { _ in 700 }, kind: request.kind.rightColumnKind,
                                                   holds: { _, kind in kind == .browser }) == .pane("web"),
                "a search still reuses the chat's browser pane")
        #expect(NewTabPage.browserURL(request, services: services) == expected, "chat-dock browser destination")
        #expect(NewTabSubmit.plan(text: request.text, search: request.search, agent: nil, resolver: resolver,
                                 fixesHostTypos: true) == .browser(expected), "ordinary-pane browser destination")
    }

    @Test(arguments: [false, true]) func nativeBrowserURLAndExplicitSearchKeepTheirDestination(search: Bool) throws {
        let (services, pane, _) = try Self.pane(withTerminal: false)
        defer { pane.teardown() }
        let resolver = services.cache.suggestionEngine.resolver
        let text = "https://example.com/path?q=value#section"
        let request = try #require(NewTabSubmit.nativeRequest(text: text, kind: .browser, search: search, cwd: nil, resolver: resolver))
        let expected = try #require(search ? resolver.searchEngine.searchURL(for: text) : URL(string: text))
        #expect(NewTabPage.browserURL(request, services: services) == expected)
        #expect(NewTabSubmit.plan(text: request.text, search: request.search, agent: nil, resolver: resolver,
                                 fixesHostTypos: true) == .browser(expected))
    }

    @Test func nativeBrowserTypoFixIsNotLostWhenPlacementResolvesTheURLAgain() throws {
        let (services, pane, _) = try Self.pane(withTerminal: false)
        defer { pane.teardown() }
        let resolver = services.cache.suggestionEngine.resolver
        let request = try #require(NewTabSubmit.nativeRequest(text: "https://example.cmo/path", kind: .browser,
                                                             search: false, cwd: nil, resolver: resolver))
        let expected = try #require(URL(string: "https://example.com/path"))
        #expect(!resolver.hostTypoMemory.allowsFix(of: "example.cmo"), "classification already consumed the typo fix")
        #expect(NewTabPage.browserURL(request, services: services) == expected)
        #expect(NewTabSubmit.plan(text: request.text, search: request.search, agent: nil, resolver: resolver,
                                 fixesHostTypos: true) == .browser(expected))
        let searched = try #require(NewTabSubmit.nativeRequest(text: "https://example.cmo/path", kind: .browser,
                                                              search: true, cwd: nil, resolver: resolver))
        #expect(NewTabPage.browserURL(searched, services: services) == resolver.searchEngine.searchURL(for: "https://example.cmo/path"))
    }

    @Test func emptyBrowserAndAgentPicksKeepTheirKinds() throws {
        let resolver = OmniboxResolver()
        for kind in [AgentPaneTabKind.browser, .agent] {
            let request = try #require(NewTabSubmit.nativeRequest(text: " ", kind: kind, search: false, cwd: nil, resolver: resolver))
            #expect(request.kind == kind && request.text.isEmpty)
        }
        let prompt = try #require(NewTabSubmit.nativeRequest(text: "fix the tests", kind: .agent, search: false, cwd: nil, resolver: resolver))
        #expect(prompt.kind == .agent)
        #expect(NewTabSubmit.plan(text: prompt.text, search: prompt.search, agent: nil, resolver: resolver) == .chat(prompt: "fix the tests", harness: nil))
    }

    @Test(arguments: [AgentPaneTabKind.terminal, .browser]) func nativeTerminalPicksInAnOrdinaryPaneDoNotConsultLinkPlacement(kind: AgentPaneTabKind) throws {
        let (services, pane, _) = try Self.pane(withTerminal: true)
        defer { pane.teardown() }
        var consultedPlacement = false
        services.linkOpener.placement = { consultedPlacement = true; return .splitRight }
        #expect(NewTabPage.submitNative(kind == .terminal ? "echo hello" : "!echo hello", kind: kind,
                                       search: false, cwd: "/project", in: pane))
        #expect(!consultedPlacement, "ordinary native picks replace the page without splitting")
    }

    /// `newTab.picksFollowLinks` on: the pick goes where links go, beside the page.
    @Test func optedInThePickFollowsLinkPlacement() throws {
        #expect(try Self.pickConsultsLinkPlacement(.splitRight, withTerminal: true, optedIn: true))
        let (_, pane, page) = try Self.pane(withTerminal: true, optedIn: true)
        defer {
            pane.teardown()
            _ = TunableStore.shared.set(AgentPaneTunables.newTabPicksFollowLinks.key, nil)
        }
        #expect(NewTabPage.opensBeside(page, in: pane))
    }
}
