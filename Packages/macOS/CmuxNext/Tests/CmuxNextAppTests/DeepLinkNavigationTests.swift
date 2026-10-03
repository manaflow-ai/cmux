import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// `link.open`'s success paths, through the jump code a user's own Go To
/// runs: the window shows the target's workspace, the tab is selected, and
/// the window comes forward with the intent the run allows (recorded
/// through `AppServices.showJumpWindow`, so no window goes on screen).
@MainActor
@Suite struct DeepLinkNavigationTests {
    static let hex = DeepLinkHandlerTests.hex
    static let otherHex = "fedcba9876543210fedcba9876543210"
    static let key = "0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01"
    static let otherKey = "0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c02"
    static let workspaceID = "ws_" + hex
    static let paneID = "pane_" + hex
    static let firstTab = "tab_" + hex
    static let secondTab = "tab_" + otherHex

    final class Recorder {
        var intents: [WindowActivation.Intent] = []
    }

    /// w1 holds one pane of two tabs, its second the daemon's default; w2 one
    /// plain tab. The window lists both and shows w2.
    static func fixture(resourceIDs: Bool = true) throws -> (AppServices, WindowController, Recorder) {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let recorder = Recorder()
        services.showJumpWindow = { _, intent in recorder.intents.append(intent) }
        let tabs = [
            TabSnapshot(surface: 5, tabResourceID: resourceIDs ? ResourceID(rawValue: firstTab) : nil, title: "one"),
            TabSnapshot(surface: 6, tabResourceID: resourceIDs ? ResourceID(rawValue: secondTab) : nil, title: "two"),
        ]
        let pane = PaneSnapshot(id: 3, resourceID: resourceIDs ? ResourceID(rawValue: paneID) : nil, activeTab: 1, tabs: tabs)
        let first = WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: key), resourceID: resourceIDs ? ResourceID(rawValue: workspaceID) : nil,
                                      name: "w1", screens: [ScreenSnapshot(id: 4, layout: .leaf(3), panes: [pane])])
        let other = WorkspaceSnapshot(id: 2, key: WorkspaceKey(rawValue: otherKey), name: "w2", screens: [
            ScreenSnapshot(id: 14, layout: .leaf(13), panes: [PaneSnapshot(id: 13, tabs: [TabSnapshot(surface: 15, title: "three")])]),
        ])
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [first, other]))
        let window = try #require(services.windows.openWindow(workspaces: [key, otherKey]))
        services.windows.select(otherKey, in: window.state)
        return (services, window, recorder)
    }

    /// A user's run (the OS handler, the palette), optionally in the background.
    static func open(_ services: AppServices, _ path: String, background: Bool? = nil) -> ControlActionOutcome {
        var arguments: [String: ControlValue] = ["url": .string("\(services.linkScheme)://\(path)")]
        if let background { arguments["background"] = .bool(background) }
        return RegistryControlBridge(registry: services.registry)
            .perform(ControlActionRequest(actionID: "link.open", arguments: arguments, origin: "user"))
    }

    @Test func aTabLinkSelectsTheTabInItsWorkspace() throws {
        let (services, window, recorder) = try Self.fixture()
        defer { window.window?.close() }
        #expect(Self.open(services, "tab/\(Self.firstTab)") == .ran)
        #expect(window.state.workspaceID == Self.key)
        #expect(window.state.selection.selection(in: Self.paneID) == Self.firstTab)
        #expect(recorder.intents == [.raise])
    }

    @Test func aPaneLinkLandsOnThePanesSelectedTab() throws {
        let (services, window, recorder) = try Self.fixture()
        defer { window.window?.close() }
        #expect(Self.open(services, "pane/\(Self.paneID)") == .ran)
        #expect(window.state.workspaceID == Self.key)
        #expect(window.state.selection.selection(in: Self.paneID) == Self.secondTab)
        #expect(recorder.intents == [.raise])
    }

    @Test func aWorkspaceLinkShowsTheWorkspace() throws {
        let (services, window, recorder) = try Self.fixture()
        defer { window.window?.close() }
        #expect(Self.open(services, "workspace/\(Self.workspaceID)") == .ran)
        #expect(window.state.workspaceID == Self.key)
        #expect(recorder.intents == [.raise])
    }

    /// Nightly's `workspace/<uuid>` names the durable workspace key, in any
    /// case, else its `stable_workspace_id` fallback.
    @Test func aNightlyWorkspaceLinkShowsTheWorkspace() throws {
        let upper = Self.key.uppercased()
        for path in ["workspace/\(upper)", "workspace/\(UUID().uuidString)?stable_workspace_id=\(upper)"] {
            let (services, window, recorder) = try Self.fixture()
            #expect(Self.open(services, path) == .ran, "\(path)")
            #expect(window.state.workspaceID == Self.key, "\(path)")
            #expect(recorder.intents == [.raise], "\(path)")
            window.window?.close()
        }
    }

    /// Nightly pane and surface ids have no counterpart: the workspace
    /// opens, and the refusal says the item itself was not found.
    @Test func aNightlyPaneOrSurfaceLinkShowsTheWorkspaceThenRefuses() throws {
        let item = UUID().uuidString
        for path in ["workspace/\(Self.key)/pane/\(item)", "workspace/\(Self.key)/surface/\(item)"] {
            let (services, window, recorder) = try Self.fixture()
            #expect(Self.open(services, path) == .refused(RefusalStrings.linkItemNotFound), "\(path)")
            #expect(window.state.workspaceID == Self.key, "\(path)")
            #expect(recorder.intents == [.raise], "\(path)")
            window.window?.close()
        }
    }

    /// Cmd held (`background: true`), or a run this client's user did not
    /// start (the CLI, an agent), brings the window forward without the keys.
    @Test func aBackgroundOrNonUserRunBringsTheWindowForwardWithoutTheKeys() throws {
        let (services, window, recorder) = try Self.fixture()
        defer { window.window?.close() }
        #expect(Self.open(services, "tab/\(Self.firstTab)", background: true) == .ran)
        let link = "\(services.linkScheme)://tab/\(Self.secondTab)"
        let cli = RegistryControlBridge(registry: services.registry)
            .perform(ControlActionRequest(actionID: "link.open", arguments: ["url": .string(link)]))
        #expect(cli == .ran)
        #expect(window.state.selection.selection(in: Self.paneID) == Self.secondTab)
        #expect(recorder.intents == [.bringForward, .bringForward])
    }

    /// A tab first seen without a `tab_` id keeps its first id; a link by
    /// the resource id it got later still finds and selects it.
    @Test func aTabIsFoundByTheResourceIDItGotLater() throws {
        let (services, window, recorder) = try Self.fixture(resourceIDs: false)
        defer { window.window?.close() }
        let entity = TabSnapshot(surface: 6, tabResourceID: ResourceID(rawValue: Self.secondTab), title: "two")
        services.daemon.store.apply(.tabChanged(TabDelta(workspace: 1, screen: 4, pane: 3, surface: 6, index: 1, entity: entity)))
        let (tab, pane) = try #require(services.locateTab(Self.secondTab))
        #expect(tab.id != Self.secondTab, "the fixture must keep the tab's first id")
        #expect(Self.open(services, "tab/\(Self.secondTab)") == .ran)
        #expect(window.state.selection.selection(in: pane.id) == tab.id)
        #expect(recorder.intents == [.raise])
    }

    /// A session already shown in a tab selects that tab; no second tab
    /// opens. Its turn waits for the page.
    @Test func aSessionShownInATabReusesTheTab() throws {
        let (services, window, recorder) = try Self.fixture()
        defer {
            services.agentTabs.closePane(Self.paneID)
            window.window?.close()
        }
        let key = services.agentTabs.open(in: Self.paneID, of: services.daemon.store, session: "s-1")
        #expect(Self.open(services, "session/s-1#turn-t-4") == .ran)
        #expect(services.agentTabs.tabIDs(in: Self.paneID) == [key])
        #expect(window.state.workspaceID == Self.key)
        #expect(window.state.selection.selection(in: Self.paneID) == key)
        #expect(services.agentTabs.pendingTurn(in: key) == "t-4")
        #expect(recorder.intents == [.raise])
    }

    /// An unknown workspace is refused and the window keeps what it shows.
    @Test func aWorkspaceLinkToAnUnknownWorkspaceIsRefused() throws {
        let (services, window, recorder) = try Self.fixture()
        defer { window.window?.close() }
        #expect(Self.open(services, "workspace/ws_\(Self.otherHex)") == .refused(RefusalStrings.linkTargetGone))
        #expect(window.state.workspaceID == Self.otherKey)
        #expect(recorder.intents.isEmpty)
    }
}
