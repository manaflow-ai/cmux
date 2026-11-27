import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
import Foundation
import Testing

/// cmux#37365 ("i dont want this by default"): the Chief is never docked unless the person docks it. A fresh
/// window, a link clicked in the Chief with default settings, and a relaunch of a window whose Chief was docked
/// and open all leave the Chief undocked and off screen until the person asks. `ChiefPanelWindowTests` covers the
/// panel's own moves; these pin the defaults.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChiefNeverDockedByDefaultTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture
    static let keys = ChiefPanelWindowTests.keys

    /// Nothing docks and no Chief shows on screen, in this arrangement.
    static func expectNoChief(_ f: Fixture, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!f.controller.frameChiefPanelShown, "\(step): the Chief shows", sourceLocation: sourceLocation)
        #expect(f.state.docks.isEmpty, "\(step): a workspace docked: \(f.state.docks.all.map(\.workspace))", sourceLocation: sourceLocation)
        #expect(!f.state.chiefPanel.isOpen, "\(step): the Chief panel is open", sourceLocation: sourceLocation)
    }

    /// A new window with no record: the Chief panel is closed and floating, and no workspace the window shows (Home
    /// or another) docks it.
    @Test func aFreshWindowNeverDocksTheChief() async throws {
        let (chief, _) = ChiefPanelWindowTests.chiefView()
        let f = try await ChiefPanelWindowTests.fixture(chief)
        defer { f.close() }
        #expect(ChiefPanel().placement == .floating && !ChiefPanel().isOpen, "the panel's default is not closed and floating")
        #expect(f.state.chiefPanel == ChiefPanel(), "a fresh window's panel is not the default")
        Self.expectNoChief(f, "fresh, on Home")
        for id in ["k1", "k2", "k3", "k0"] {
            f.services.windows.show(workspaceID: id, in: f.state, from: .thisWindow)
            f.frame()
            Self.expectNoChief(f, "fresh, showing \(id)")
        }
    }

    /// A link clicked in the Chief through the app's own entry point (`chiefLinkWillOpen`, default settings) opens
    /// its workspace with the Chief floating over it: never docked, and nothing docked as a workspace.
    @Test func aLinkWithDefaultSettingsFloatsTheChiefAndNeverDocksIt() async throws {
        let (chief, _) = ChiefPanelWindowTests.chiefView()
        let f = try await ChiefPanelWindowTests.fixture(chief)
        defer { f.close() }
        WindowDockActions(host: f.services).chiefLinkWillOpen(in: f.controller)
        f.services.windows.show(workspaceID: "k1", in: f.state) // the link's jump
        f.frame()
        #expect(f.controller.frameChiefPanelShown, "the link opened no Chief")
        #expect(f.state.chiefPanel.dockedEdge == nil, "a link docked the Chief")
        #expect(f.state.docks.isEmpty, "a link docked a workspace")
        #expect(f.controller.content?.contentView.frame == f.controller.root.contentHost.bounds,
                "the Chief took space from the workspace, as a dock does")
    }

    /// A window saved with the Chief docked and open (an earlier session's choice) relaunches with no Chief on
    /// screen and nothing docked: a launch never pins the Chief.
    @Test func aRelaunchOfADockedOpenChiefShowsNoChief() async throws {
        let (chief, _) = ChiefPanelWindowTests.chiefView()
        let f = try await ChiefPanelWindowTests.fixture(chief)
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        f.controller.dockChiefPanel(at: .left)
        f.frame()
        try #require(f.controller.frameChiefPanelShown && f.state.chiefPanel.dockedEdge == .left)
        let record = try #require(f.services.windows.registry.value.record(f.state.id, state: f.state, order: 0))
        try #require(record.chiefPanel?.open == true && record.chiefPanel?.placement == "left", "the record does not hold the docked Chief")
        let json = try #require(String(data: try JSONEncoder().encode(record), encoding: .utf8))
        f.close()

        let again = try await Fixture(keys: Self.keys, record: json, tree: ChiefPanelWindowTests.tree())
        defer { again.close() }
        // The panel can mount the Chief's view, so "shows no Chief" below is the restore's doing, not a missing view.
        again.controller.chiefPanelSource = { chief }
        again.services.windows.show(workspaceID: "k1", in: again.state, from: .thisWindow)
        again.frame()
        Self.expectNoChief(again, "after the relaunch")
        for id in ["k2", "k0", "k3"] {
            again.services.windows.show(workspaceID: id, in: again.state, from: .thisWindow)
            again.frame()
            Self.expectNoChief(again, "relaunched, showing \(id)")
        }
        // Only the person brings it back (Show/Hide Chief, Cmd-I), the way they had placed it.
        #expect(again.controller.toggleChiefPanel(), "Show/Hide Chief could not show the Chief")
        again.frame()
        #expect(again.controller.frameChiefPanelShown, "the panel could not show the Chief at all: the checks above prove nothing")
    }
}
