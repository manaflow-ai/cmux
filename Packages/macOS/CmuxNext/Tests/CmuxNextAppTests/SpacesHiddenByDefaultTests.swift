import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPalette
import Foundation
import Testing

/// Spaces stay out of sight until the person has a second one (Lawrence 2026-11-20: "hide spaces by default,
/// but people can still cmd shift p new space"). With one space the Window menu shows no New, Previous or Next
/// Space, and the right-click menus show no New Space, New Incognito Space or Move/Duplicate to Space; the command
/// palette still offers every space action, New Space first. A second space brings every row back. The sidebar's
/// strip follows the same rule (`SidebarPinnedDefaultTests`).
@MainActor @Suite(.serialized)
struct SpacesHiddenByDefaultTests {
    /// The menu rows that advertise spaces: hidden with one space, shown with two.
    nonisolated static let windowMenuRows: [String] = ["space.new", "space.previous", "space.next"]
    nonisolated static let sidebarMenuRows: [String] = ["space.new", "space.newIncognito"]
    nonisolated static let workspaceMenuRows: [String] = ["workspace.moveToSpace", "workspace.duplicateToSpace"]

    /// The app's services and actions on a local daemon that has spaces (`profiles-v1`) and `spaces` of them.
    private func services(spaces: Int) throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        mirror(spaces: spaces, into: services)
        return services
    }

    /// The daemon reports `count` spaces (as after New Space, once the home store mirrors it).
    private func mirror(spaces count: Int, into services: AppServices) {
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1", screens: []),
        ])
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: (0..<count).map { ProfileSnapshot(id: ProfileID(rawValue: "space-\($0)"), name: "Space \($0 + 1)", index: $0) },
            pins: [],
            workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0)])
        services.machines.local.store.apply(snapshot: tree)
    }

    /// The Window menu's rows macOS shows after validating them, as it does each time the menu opens.
    private func shownWindowRows(_ services: AppServices) throws -> Set<String> {
        let bar = MainMenu.make(registry: services.registry)
        let window = try #require(MainMenuPlacementTests.topMenu(.window, in: bar))
        window.update()
        return Set(window.items.filter { !$0.isHidden }.compactMap { $0.representedObject as? String })
    }

    /// Every action a right-click menu runs, its submenus' too.
    private func actions(in menu: NSMenu) -> Set<String> {
        Set(menu.items.flatMap { item in
            (ActionRegistry.menuRun(of: item).map { [$0.id.rawValue] } ?? []) + (item.submenu.map { Array(actions(in: $0)) } ?? [])
        })
    }

    private func sidebarMenu(_ services: AppServices) -> Set<String> {
        actions(in: services.registry.makeContextMenu(for: .sidebarBackground))
    }

    private func workspaceMenu(_ services: AppServices) -> Set<String> {
        actions(in: services.registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "k1")))
    }

    @Test func oneSpaceKeepsSpacesOutOfTheWindowMenu() throws {
        let services = try services(spaces: 1)
        let shown = try shownWindowRows(services)
        for id in Self.windowMenuRows { #expect(!shown.contains(id), "\(id) shows in Window with one space") }
        #expect(shown.contains("newWindow"), "New Window left the Window menu")
    }

    @Test func oneSpaceKeepsSpacesOutOfTheRightClickMenus() throws {
        let services = try services(spaces: 1)
        let sidebar = sidebarMenu(services), workspace = workspaceMenu(services)
        for id in Self.sidebarMenuRows { #expect(!sidebar.contains(id), "\(id) shows in the sidebar's menu with one space") }
        for id in Self.workspaceMenuRows { #expect(!workspace.contains(id), "\(id) shows in the workspace menu with one space") }
    }

    /// The palette keeps New Space and the rest while the menus leave them out.
    @Test func oneSpaceStillOffersNewSpaceInThePalette() throws {
        let services = try services(spaces: 1)
        let listed = Set(RegistryPaletteProvider(registry: services.registry).makeItems().compactMap(\.actionID))
        #expect(listed.contains("space.new"), "the palette lost New Space")
        #expect(listed.contains("space.newIncognito"), "the palette lost New Incognito Space")
        #expect(listed.contains("workspace.moveToSpace"), "the palette lost Move Workspace to Space")
    }

    /// The person makes a second space: every row comes back, with no relaunch and no setting.
    @Test func aSecondSpaceBringsTheRowsBack() throws {
        let services = try services(spaces: 1)
        #expect(try shownWindowRows(services).isDisjoint(with: Self.windowMenuRows))
        mirror(spaces: 2, into: services)
        let shown = try shownWindowRows(services)
        for id in Self.windowMenuRows { #expect(shown.contains(id), "\(id) is still hidden with two spaces") }
        let sidebar = sidebarMenu(services)
        for id in Self.sidebarMenuRows { #expect(sidebar.contains(id), "\(id) is still out of the sidebar's menu with two spaces") }
        #expect(workspaceMenu(services).contains("workspace.moveToSpace"), "Move Workspace to Space is still hidden with two spaces")
    }

    /// An incognito space is its incognito window's own: it never counts as the person's second space.
    @Test func anIncognitoSpaceIsNoSecondSpace() throws {
        let services = try services(spaces: 2)
        services.windows.incognitoSpaceMarks.mark(ProfileID(rawValue: "space-1"))
        let shown = try shownWindowRows(services)
        for id in Self.windowMenuRows { #expect(!shown.contains(id), "\(id) shows because of an incognito space") }
    }
}
