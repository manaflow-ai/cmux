import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import Foundation
import Testing

/// Lawrence 2026-10-09: "you need to be able to link to a subagent so I can just click here to
/// get to it". A Chief message names a subagent as `[a1](cmux://chief/<home id>/session/<id>)`
/// (optchat-chief `workspaces::subagent_link`); `link.open` (the one shared path: the Home click,
/// the OS handler, the palette, `cmux link open`) selects the tab that shows that session in the
/// Chief home's acpmux. It opens only this app's Chief's own subagent tabs, never a new tab.
@MainActor
@Suite struct ChiefSubagentLinkTests {
    static let chief = "chief:0a1b2c3d"
    static let session = "01a12318-9c7f-7000-beab-7686172b0ca3"
    typealias Nav = DeepLinkNavigationTests

    /// The entry point (`action.run link.open`): the subagent's workspace shows, its chat tab is selected.
    @Test func aSubagentLinkSelectsItsChatTabInItsWorkspace() throws {
        let (services, window, recorder) = try Nav.fixture(agentSession: Self.session, agentHost: Self.chief)
        defer { window.window?.close() }
        services.agentTabs.chiefHost = Self.chief
        #expect(Nav.open(services, "chief/0a1b2c3d/session/\(Self.session)") == .ran)
        #expect(window.state.workspaceID == Nav.key)
        #expect(window.state.selection.selection(in: Nav.paneID) == Nav.agentTab)
        #expect(recorder.intents == [.raise])
    }

    /// Another Chief home's link, a session no subagent tab shows, and a tab of this Mac's own
    /// acpmux on the same session id are refused; nothing moves and no tab is made.
    @Test func onlyThisChiefsShownSubagentOpens() throws {
        let (services, window, _) = try Nav.fixture(agentSession: Self.session, agentHost: Self.chief)
        defer { window.window?.close() }
        services.agentTabs.chiefHost = Self.chief
        let tabs = services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).count
        #expect(Nav.open(services, "chief/ffffffff/session/\(Self.session)") == .refused(RefusalStrings.linkTargetGone))
        #expect(Nav.open(services, "chief/0a1b2c3d/session/other") == .refused(RefusalStrings.linkTargetGone))
        #expect(window.state.workspaceID == Nav.otherKey, "nothing moved")
        #expect(services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).count == tabs)
        let (local, localWindow, _) = try Nav.fixture(agentSession: Self.session)
        defer { localWindow.window?.close() }
        local.agentTabs.chiefHost = Self.chief
        #expect(Nav.open(local, "chief/0a1b2c3d/session/\(Self.session)") == .refused(RefusalStrings.linkTargetGone))
    }

    /// Home's click on a subagent link (agent text, any build): the link names the `cmux` scheme,
    /// the app runs it as its own build's `link.open`, and refuses any other app link.
    @Test func homesClickRunsLinkOpenInThisBuildsScheme() throws {
        let (services, window, _) = try Nav.fixture(agentSession: Self.session, agentHost: Self.chief)
        defer { window.window?.close() }
        services.agentTabs.chiefHost = Self.chief
        let url = try #require(URL(string: "cmux://chief/0a1b2c3d/session/\(Self.session)"))
        #expect(ChiefSubagentLinks.open(url, services: services))
        #expect(window.state.selection.selection(in: Nav.paneID) == Nav.agentTab)
        for other in ["cmux://tab/tab_\(Nav.hex)", "cmux://chief/ffffffff/session/\(Self.session)", "https://cmux.com"] {
            #expect(!ChiefSubagentLinks.open(try #require(URL(string: other)), services: services), "\(other)")
        }
    }
}
