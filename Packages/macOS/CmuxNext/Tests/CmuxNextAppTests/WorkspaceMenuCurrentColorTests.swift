import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import Foundation
import Testing

/// Lucas 2026-11-24: a red workspace's right-click menu rang No Color, not red. The color action had
/// no current choice, so no row of its submenu was checked and the header's swatches fell back to
/// No Color. The workspace's own color is the checked row, and the header rings that swatch.
@MainActor @Suite(.serialized, .closesItsWindows)
struct WorkspaceMenuCurrentColorTests {
    private static func services(color: String?) throws -> (AppServices, ActionTargetRef) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        // The color action needs the daemon's workspace metadata; without it the menu has no colors.
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":[""# + DaemonCapability.workspaceMetadata.rawValue + #""]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "red-ws"), name: "red", color: color),
        ]))
        let workspace = try #require(store.workspaces.first)
        return (services, ActionTargetRef(kind: .workspace, id: workspace.id))
    }

    @Test func theWorkspacesColorIsTheCheckedRowAndTheRingedSwatch() throws {
        let (services, target) = try Self.services(color: GroupColor.red.rawValue)
        let registry = services.registry
        let menu = registry.makeContextMenu(for: .workspaceRow, target: target)
        let colorRows = menu.items.compactMap(\.submenu).flatMap(\.items).filter { MenuIdentityHeader.color(of: $0) != nil }
        try #require(colorRows.count >= 2, "the workspace menu lists its colors")
        #expect(colorRows.filter { $0.state == .on }.compactMap(MenuIdentityHeader.color(of:)) == [.red])

        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "red", rename: "renameWorkspace")
        let strip = try #require((menu.items.first?.view as? MenuIdentityHeaderView)?.strip)
        #expect(strip.current == .red, "the red swatch is ringed")
        #expect(!strip.clearIsCurrent, "No Color is not ringed")
    }

    /// The sidebar accepts `gray` for the `grey` swatch; the menu rings it too.
    @Test func aStoredGrayRingsTheGreySwatch() throws {
        let (services, target) = try Self.services(color: "gray")
        let registry = services.registry
        let menu = registry.makeContextMenu(for: .workspaceRow, target: target)
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "red", rename: "renameWorkspace")
        let strip = try #require((menu.items.first?.view as? MenuIdentityHeaderView)?.strip)
        #expect(strip.current == .grey)
    }

    @Test func aWorkspaceWithNoColorRingsNoColor() throws {
        let (services, target) = try Self.services(color: nil)
        let registry = services.registry
        let menu = registry.makeContextMenu(for: .workspaceRow, target: target)
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "red", rename: "renameWorkspace")
        let strip = try #require((menu.items.first?.view as? MenuIdentityHeaderView)?.strip)
        #expect(strip.current == nil)
        #expect(strip.clearIsCurrent)
    }
}
