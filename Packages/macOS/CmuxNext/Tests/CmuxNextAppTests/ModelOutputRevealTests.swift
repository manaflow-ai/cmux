import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// Media safety R8 (leo-workspace#874): a workspace, pane or tab link clicked in model output
/// shows its target only in a window that already lists the workspace. Revealing a workspace no
/// window lists claims it into the active window, or opens a new window (WindowManager.reveal),
/// so from model output it answers "not open" and the windows stay as they were. The person's
/// own link to the same workspace still shows it in a window.
@MainActor @Suite(.serialized)
struct ModelOutputRevealTests {
    nonisolated private static let workspace = "ws_0123456789abcdef0123456789abcdef"
    nonisolated private static let pane = "pane_0123456789abcdef0123456789abcdef"
    nonisolated private static let tab = "tab_0123456789abcdef0123456789abcdef"
    nonisolated private static let key = "3f2a9c1e-7d4b-4e8a-9c11-2e5f6a7b8c9d"

    /// App services whose store has one workspace (with one pane and one tab) that no window lists.
    private static func services() throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"r8-reveal-test","generation":"g1"}"#
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        let tab = TabSnapshot(surface: 1, tabResourceID: ResourceID(rawValue: Self.tab), title: "~")
        let pane = PaneSnapshot(id: 1, resourceID: ResourceID(rawValue: Self.pane), tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: Self.key), resourceID: ResourceID(rawValue: Self.workspace),
                              name: "r8", screens: [screen]),
        ]))
        AppActions.bind(services)
        return services
    }

    private static func workspaceID(_ services: AppServices) throws -> String {
        try #require(services.daemon.store.workspaces.first?.id)
    }

    /// No window lists the workspace, and no window was opened.
    private static func untouched(_ services: AppServices) throws -> Bool {
        let id = try workspaceID(services)
        return services.windows.registry.value.owner(of: id) == nil && services.windows.controllers.isEmpty
    }

    private static func click(_ link: DeepLink, _ origin: DeepLink.Origin, _ services: AppServices) throws -> String? {
        let url = try #require(link.url(scheme: services.linkScheme))
        return services.registry.capturingRefusal { _ = CmuxAppLinks.open(url, services: services, origin: origin) }
    }

    private static func close(_ services: AppServices) {
        for controller in services.windows.controllers { controller.window?.close() }
    }

    @Test(arguments: [DeepLink.Target.workspace(workspace), .pane(pane), .tab(tab)])
    func aModelOutputLinkNeverClaimsOrOpensAWindow(_ target: DeepLink.Target) throws {
        let services = try Self.services()
        defer { Self.close(services) }
        try #require(try Self.untouched(services), "a window listed the workspace before the link")
        let link = DeepLink(target)
        let refusal = try Self.click(link, .modelOutput, services)
        #expect(refusal == RefusalStrings.linkTargetNotOpen(services.linkText(link) ?? ""))
        #expect(try Self.untouched(services), "a model-output \(target) link claimed the workspace or opened a window")
    }

    @Test(arguments: [DeepLink.Target.workspace(workspace), .pane(pane), .tab(tab)])
    func thePersonsLinkShowsTheWorkspaceInAWindow(_ target: DeepLink.Target) throws {
        let services = try Self.services()
        defer { Self.close(services) }
        try #require(try Self.untouched(services))
        let refusal = try Self.click(DeepLink(target), .person, services)
        #expect(refusal == nil, "refused: \(refusal ?? "")")
        #expect(services.windows.registry.value.owner(of: try Self.workspaceID(services)) != nil, "no window shows the workspace")
    }

    /// Nightly's links never reach the navigator from a chat (CmuxAppLinks refuses them), and the
    /// navigator itself still opens nothing for one from model output.
    @Test func aLegacyLinkFromModelOutputOpensNothing() throws {
        let services = try Self.services()
        defer { Self.close(services) }
        let uuid = try #require(UUID(uuidString: Self.key))
        for target in [DeepLink.Target.legacyWorkspace(uuid, fallback: nil), .legacyPane(workspace: uuid, pane: uuid),
                       .legacySurface(workspace: uuid, surface: uuid, fallbackWorkspace: nil, fallbackSurface: nil)] {
            #expect(throws: ActionFailure.self) {
                try DeepLinkNavigator(services: services).open(DeepLink(target), background: true, origin: .modelOutput)
            }
            #expect(try Self.untouched(services), "a model-output \(target) link claimed the workspace or opened a window")
        }
        try DeepLinkNavigator(services: services).open(DeepLink(.legacyWorkspace(uuid, fallback: nil)), background: true)
        #expect(services.windows.registry.value.owner(of: try Self.workspaceID(services)) != nil, "the person's link showed nothing")
    }
}
