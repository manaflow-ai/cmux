import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing

/// cmux:// links in the app: `link.open` is the one resolution path and
/// refuses what it cannot open with a reason; Copy Link writes the running
/// build's scheme and durable resource ids, never numeric handles.
@MainActor
@Suite struct DeepLinkHandlerTests {
    typealias Coverage = ActionBindingCoverageTests
    static let hex = "0123456789abcdef0123456789abcdef"

    static func tree(resourceIDs: Bool) throws -> DaemonTree {
        let ids = resourceIDs
        let workspace = ids ? #","resource_id":"ws_\#(hex)""# : ""
        let pane = ids ? #","resource_id":"pane_\#(hex)""# : ""
        let tab = ids ? #","tab_resource_id":"tab_\#(hex)""# : ""
        let json = #"{"workspace_revision":1,"generation":"GEN","registry_id":"r","workspaces":[{"id":1,"key":"0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01","name":"w"\#(workspace),"screens":[{"id":4,"layout":{"type":"leaf","pane":3},"panes":[{"id":3\#(pane),"active_tab":0,"tabs":[{"surface":5,"kind":"pty","title":""\#(tab)}]}]}]}]}"#
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    static func open(_ services: AppServices, _ url: String, background: Bool? = nil) -> ControlActionOutcome {
        var arguments: [String: ControlValue] = ["url": .string(url)]
        if let background { arguments["background"] = .bool(background) }
        return RegistryControlBridge(registry: services.registry).perform(ControlActionRequest(actionID: "link.open", arguments: arguments))
    }

    @Test func linkOpenIsBoundAndOnTheCLI() throws {
        let services = Coverage.boundServices()
        #expect(services.registry.isBound("link.open"))
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "link.open" })
        #expect(descriptor.cliName == "link open")
        #expect(descriptor.isPaletteVisible)
        #expect(descriptor.surfacePlan.mcp == .offered)
        #expect(descriptor.arguments.map(\.name) == ["url", "background"])
    }

    /// Another scheme, the sign-in callback, an unknown kind or a malformed
    /// id is refused with the link in the reason, never opened another way.
    @Test func whatIsNotALinkIsRefused() {
        let services = Coverage.boundServices()
        let scheme = services.linkScheme
        let other = scheme == "cmux" ? "cmux-dev" : "cmux"
        for url in ["https://cmux.com", "\(other)://tab/tab_\(Self.hex)", "\(scheme)://auth-callback?code=1",
                    "\(scheme)://screen/screen_\(Self.hex)", "\(scheme)://tab/7", "not a url"] {
            #expect(Self.open(services, url) == .refused(RefusalStrings.linkNotRecognized(url)), "\(url)")
        }
    }

    /// A closed, deleted or unconnected target is refused; nothing is
    /// created in its place.
    @Test func aMissingTargetIsRefused() {
        let services = Coverage.boundServices()
        let scheme = services.linkScheme
        for path in ["tab/tab_\(Self.hex)", "pane/pane_\(Self.hex)", "workspace/ws_\(Self.hex)",
                     "workspace/11111111-2222-3333-4444-555555555555",
                     "workspace/11111111-2222-3333-4444-555555555555/surface/11111111-2222-3333-4444-555555555556",
                     "tab/tab_\(Self.hex)?machine=machine_\(Self.hex)"] {
            #expect(Self.open(services, "\(scheme)://\(path)") == .refused(RefusalStrings.linkTargetGone), "\(path)")
            #expect(Self.open(services, "\(scheme)://\(path)", background: true) == .refused(RefusalStrings.linkTargetGone), "\(path)")
        }
        #expect(services.windows.controllers.isEmpty, "a missing target opens no window")
    }

    /// A session that no tab shows opens in a new agent tab in the focused
    /// pane, so with no window there is nowhere to open it.
    @Test func aSessionNeedsAFocusedPane() {
        let services = Coverage.boundServices()
        #expect(Self.open(services, "\(services.linkScheme)://session/s1#turn-t1") == .refused(MiscHandlerStrings.noPane))
    }

    @Test func copyLinkWritesTheBuildsSchemeAndResourceIDs() throws {
        let services = Coverage.boundServices()
        services.daemon.store.apply(snapshot: try Self.tree(resourceIDs: true))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let pane = try #require(workspace.screens.first?.panes.first)
        let tab = try #require(pane.tabs.first)
        let scheme = services.linkScheme
        #expect(try services.link(workspace: workspace) == "\(scheme)://workspace/ws_\(Self.hex)")
        #expect(try services.link(pane: pane) == "\(scheme)://pane/pane_\(Self.hex)")
        #expect(try services.link(tab: tab) == "\(scheme)://tab/tab_\(Self.hex)")
        // Every copied link opens through link.open's parser.
        for text in [try services.link(workspace: workspace), try services.link(pane: pane), try services.link(tab: tab)] {
            #expect(DeepLink.parse(try #require(URL(string: text)), scheme: scheme) != nil, "\(text)")
        }
    }

    /// A daemon without resource ids gets a refusal, never a link built
    /// from a numeric handle.
    @Test func copyLinkRefusesWithoutAResourceID() throws {
        let services = Coverage.boundServices()
        services.daemon.store.apply(snapshot: try Self.tree(resourceIDs: false))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let pane = try #require(workspace.screens.first?.panes.first)
        let tab = try #require(pane.tabs.first)
        #expect(throws: ActionFailure(message: RefusalStrings.noLinkID)) { try services.link(workspace: workspace) }
        #expect(throws: ActionFailure(message: RefusalStrings.noLinkID)) { try services.link(pane: pane) }
        #expect(throws: ActionFailure(message: RefusalStrings.noLinkID)) { try services.link(tab: tab) }
        // Through the actions, on an explicit target.
        let workspaceRef = ActionTargetRef(kind: .workspace, id: workspace.id)
        #expect(Coverage.run(services, "palette.copyWorkspaceLink", target: workspaceRef) == .refused(RefusalStrings.noLinkID))
        let tabRef = ActionTargetRef(kind: .tab, id: tab.id)
        #expect(Coverage.run(services, "palette.copySurfaceLink", target: tabRef) == .refused(RefusalStrings.noLinkID))
        #expect(Coverage.run(services, "palette.copyPaneLink", target: tabRef) == .refused(RefusalStrings.noLinkID))
    }

    @Test func copyLinkWithoutATargetIsRefused() {
        let services = Coverage.boundServices()
        #expect(Coverage.run(services, "palette.copyWorkspaceLink") == .refused(RefusalStrings.noWorkspaceToActOn))
        #expect(Coverage.run(services, "palette.copySurfaceLink") == .refused(MiscHandlerStrings.noPane))
        let missing = ActionTargetRef(kind: .tab, id: "missing")
        #expect(Coverage.run(services, "palette.copySurfaceLink", target: missing) == .refused("no tab missing"))
        #expect(Coverage.run(services, "palette.copyPaneLink", target: missing) == .refused("no tab missing"))
    }
}
