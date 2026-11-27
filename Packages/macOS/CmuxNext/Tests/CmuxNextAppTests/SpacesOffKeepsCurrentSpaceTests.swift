import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/48355: Spaces is off by default, and nothing makes or switches
/// spaces while it is. A person whose window shows a space other than the default when it turns off (New Window
/// gave each window its own) keeps that window as it is: same space, same workspaces, same selection. Nothing is
/// moved, merged or deleted, and New Window still opens its own view.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SpacesOffKeepsCurrentSpaceTests {
    @Test func aWindowOnANonDefaultSpaceKeepsItsSidebarWhenSpacesTurnsOff() async throws {
        let fixture = try await Fixture(settings: #"{"sidebar":{"showSpaces":true}}"#)
        defer { fixture.close() }
        let windows = fixture.services.windows
        // Spaces on: the window shows Work, on its second workspace.
        windows.switchProfile(Fixture.work, in: fixture.state)
        windows.select("k3", in: fixture.state)
        #expect(fixture.state.profileID == Fixture.work)
        #expect(fixture.shown == ["k2", "k3"])
        #expect(fixture.services.windowHomeMembers(fixture.state.id) == ["k2", "k3"],
                "Home lookup received workspaces hidden by the current space")

        // cmux.json loses the key (an upgrade to the default-off build): Spaces turns off.
        try await fixture.write("{}")
        #expect(!windows.spacesOn)
        #expect(fixture.state.profileID == Fixture.work, "Spaces off moved the window to \(fixture.state.profileID.rawValue)")
        #expect(fixture.state.workspaceID == "k3", "the selected workspace changed")
        #expect(fixture.shown == ["k2", "k3"], "the window's workspaces changed")
        #expect(fixture.store.profileIDs == [.defaultProfile, Fixture.work], "a space was removed")
        #expect(WindowProfiles.visible(["k1", "k2", "k3"], profile: .defaultProfile, machines: fixture.services.machines) == ["k1"],
                "a workspace changed space")

        // Nothing swaps the sidebar out: not a direct switch, not Previous Space.
        windows.switchProfile(.defaultProfile, in: fixture.state)
        _ = fixture.services.registry.perform("space.previous")
        #expect(fixture.state.profileID == Fixture.work)
        #expect(fixture.shown == ["k2", "k3"])

        // Every way to make or move into a space is off, with the reason a CLI or MCP caller reads.
        let registry = fixture.services.registry
        for id: ActionID in ["space.new", "space.newIncognito", "space.next", "space.switch", "workspace.moveToSpace", "browser.link.openInNewSpace"] {
            #expect(!registry.isAvailable(id), "\(id.rawValue) is still offered")
            #expect(registry.unavailableReason(for: id) == RoomStrings.spacesOff)
        }
        #expect(registry.unavailableReason(for: "space.setTheme") == nil, "Settings edits the shown space's theme")
        #expect(registry.unavailableReason(for: "newWindow") == nil, "New Window keeps working")
        #expect(!registry.perform("space.new"))
        #expect(fixture.store.profileIDs.count == 2)

        // A workspace of another space no open window lists (a closed window's; picked in the palette or a
        // notification) opens in a window of its own. This window keeps its view.
        windows.claim(workspaceID: "k4", in: fixture.state)
        #expect(fixture.state.profileID == Fixture.work, "a claim swapped this window's sidebar")
        #expect(fixture.shown == ["k2", "k3"])
        let owner = try #require(windows.registry.value.owner(of: "k4"))
        #expect(owner != fixture.state.id)
        #expect(windows.state(for: owner).profileID == .defaultProfile)
        let other = try #require(windows.controller(for: owner))
        defer { other.teardown(); other.window?.close() }
        // Asked again while that window is open: it shows there; no third window.
        let openCount = windows.registry.value.openWindows.count
        windows.claim(workspaceID: "k4", in: fixture.state)
        #expect(windows.registry.value.owner(of: "k4") == owner)
        #expect(windows.registry.value.openWindows.count == openCount)
        #expect(fixture.state.profileID == Fixture.work)

        // Dragged onto this window's sidebar: it joins this window (pinned to Work); the window keeps its view.
        windows.moveWorkspaces(["k4"], toWindow: fixture.state.id)
        #expect(windows.registry.value.owner(of: "k4") == fixture.state.id)
        #expect(fixture.state.profileID == Fixture.work, "a move swapped this window's sidebar")
        // The pin lands (the fixture's daemon has no connection: its reply is applied here): k4 shows in Work and is selected.
        fixture.store.apply(snapshot: Fixture.tree(pinned: ["k4": Fixture.work]))
        windows.reconcileMembership()
        #expect(fixture.shown == ["k2", "k3", "k4"])
        #expect(fixture.state.workspaceID == "k4", "the moved workspace was not selected once it showed")
        #expect(windows.pinSelections.isEmpty)
    }

    /// A pick of a workspace the window lists in another space (palette, notification, `select`) while Spaces is off:
    /// the window keeps its view, and the workspace joins it, selected once its pin lands. A pick made since wins.
    @Test func aPickOfAHiddenWorkspaceJoinsThisWindowsView() async throws {
        let fixture = try await Fixture(settings: #"{"sidebar":{"showSpaces":true}}"#)
        defer { fixture.close() }
        let windows = fixture.services.windows
        windows.switchProfile(Fixture.work, in: fixture.state)
        try await fixture.write("{}")

        windows.select("k1", in: fixture.state)
        #expect(fixture.state.profileID == Fixture.work, "a pick swapped this window's sidebar")
        #expect(windows.pinSelections["k1"]?.window == fixture.state.id)
        // Another pick before the pin lands: it stays when the pin lands, and k1 joins the view.
        windows.select("k2", in: fixture.state)
        fixture.store.apply(snapshot: Fixture.tree(pinned: ["k1": Fixture.work]))
        windows.reconcileMembership()
        #expect(fixture.state.profileID == Fixture.work)
        #expect(fixture.shown == ["k1", "k2", "k3"])
        #expect(fixture.state.workspaceID == "k2", "a landed pin took the selection from a later pick")
        #expect(windows.pinSelections.isEmpty)
    }

    /// notify-banner-click burst-click (run 46007715275): the window was on a space of its own (Move to New Window gives
    /// one) and owned the burst's chat workspaces, which the default space holds. A banner click revealed one: the window
    /// showed it at once and sent its pin. A daemon delta before the pin landed (here the previous click's pin landing)
    /// re-ran reconcile, whose selection repair found the revealed workspace outside the window's space and picked a
    /// neighbor (`via reconcile-repair`); the pin then landed for a window that no longer showed it, so nothing brought it
    /// back. A revealed workspace the window lists stays selected through every repair until its pin lands.
    @Test func aRevealedWorkspaceStaysSelectedThroughAReconcileBeforeItsPinLands() async throws {
        let fixture = try await Fixture(settings: #"{"sidebar":{"showSpaces":true}}"#)
        defer { fixture.close() }
        let windows = fixture.services.windows
        windows.switchProfile(Fixture.work, in: fixture.state)
        try await fixture.write("{}")
        #expect(fixture.state.workspaceID == "k2")

        // A banner click on k1's chat: the window lists k1 (its own, in the default space) and shows it now.
        #expect(windows.reveal(workspaceID: "k1") === fixture.controller)
        #expect(fixture.state.workspaceID == "k1")
        #expect(windows.pinSelections["k1"]?.window == fixture.state.id)
        // A daemon delta before the pin lands: reconcile must not take the reveal back.
        windows.reconcileMembership()
        #expect(fixture.state.workspaceID == "k1", "reconcile-repair undid the reveal: \(fixture.state.workspaceID ?? "nil")")
        #expect(fixture.state.profileID == Fixture.work)
        // The pin lands: k1 joins the window's view, still selected.
        fixture.store.apply(snapshot: Fixture.tree(pinned: ["k1": Fixture.work]))
        windows.reconcileMembership()
        #expect(fixture.shown == ["k1", "k2", "k3"])
        #expect(fixture.state.workspaceID == "k1")
        #expect(windows.pinSelections.isEmpty)
    }

    /// The burst's order: click one hidden workspace, then another before the first's pin lands. The first pin landing
    /// re-runs reconcile; the second click's workspace stays selected, and is still selected once its own pin lands.
    @Test func aSecondRevealSurvivesTheFirstRevealsPinLanding() async throws {
        let fixture = try await Fixture(settings: #"{"sidebar":{"showSpaces":true}}"#)
        defer { fixture.close() }
        let windows = fixture.services.windows
        windows.switchProfile(Fixture.work, in: fixture.state)
        try await fixture.write("{}")
        // k4 joins this window's list in the default space (a daemon-made workspace reconcile filed here).
        let id = fixture.state.id
        windows.transition { $0.move(["k4"], to: id) }
        #expect(!fixture.shown.contains("k4"))

        windows.reveal(workspaceID: "k1")
        windows.reveal(workspaceID: "k4")
        #expect(fixture.state.workspaceID == "k4")
        fixture.store.apply(snapshot: Fixture.tree(pinned: ["k1": Fixture.work]))
        windows.reconcileMembership()
        #expect(fixture.state.workspaceID == "k4", "the first reveal's pin landing took the second reveal back: \(fixture.state.workspaceID ?? "nil")")
        fixture.store.apply(snapshot: Fixture.tree(pinned: ["k1": Fixture.work, "k4": Fixture.work]))
        windows.reconcileMembership()
        #expect(fixture.shown == ["k1", "k2", "k3", "k4"])
        #expect(fixture.state.workspaceID == "k4")
        #expect(windows.pinSelections.isEmpty)
    }

    /// Merge All Windows while Spaces is off: the other window's workspaces join this window's view; it keeps its space.
    @Test func mergeAllKeepsThisWindowsViewAndShowsTheMergedWorkspaces() async throws {
        let fixture = try await Fixture(settings: #"{"sidebar":{"showSpaces":true}}"#)
        defer { fixture.close() }
        let windows = fixture.services.windows
        windows.switchProfile(Fixture.work, in: fixture.state)
        let other = try #require(windows.openWindow(workspaces: ["k4"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        defer { other.teardown(); other.window?.close() }
        #expect(other.state.profileID == .defaultProfile)
        try await fixture.write("{}")

        try windows.mergeWindows(into: fixture.state)
        #expect(fixture.state.profileID == Fixture.work, "Merge All swapped this window's sidebar")
        #expect(windows.registry.value.owner(of: "k4") == fixture.state.id)
        fixture.store.apply(snapshot: Fixture.tree(pinned: ["k4": Fixture.work]))
        windows.reconcileMembership()
        #expect(fixture.shown == ["k2", "k3", "k4"], "a merged workspace is hidden in this window's space")
    }

    /// Spaces on again: the switcher's actions come back and the window moves between spaces as before.
    @Test func turningSpacesBackOnRestoresSwitching() async throws {
        let fixture = try await Fixture(settings: "{}")
        defer { fixture.close() }
        let windows = fixture.services.windows
        #expect(!windows.spacesOn, "Spaces is off by default")
        windows.switchProfile(Fixture.work, in: fixture.state)
        #expect(fixture.state.profileID == .defaultProfile)

        try await fixture.write(#"{"sidebar":{"showSpaces":true}}"#)
        #expect(windows.spacesOn)
        #expect(fixture.services.registry.unavailableReason(for: "space.new") == nil)
        windows.switchProfile(Fixture.work, in: fixture.state)
        #expect(fixture.state.profileID == Fixture.work)
        #expect(fixture.shown == ["k2", "k3"])
    }

    @MainActor
    final class Fixture {
        static let work = ProfileID(rawValue: "room-work")
        let services = AppServices(environment: AppEnvironment.current([:]))
        let controller: WindowController
        let settings: SettingsController
        let url: URL
        var store: DaemonStore { services.machines.local.store }
        var state: WindowState { controller.state }
        /// The workspaces the window lists in the space it shows.
        var shown: [String] {
            WindowProfiles.visible(services.windows.registry.members(of: state.id), profile: state.profileID, machines: services.machines)
        }

        init(settings json: String) async throws {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-spaces-off-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "cmux.json")
            try Data(json.utf8).write(to: file)
            url = file
            let services = services
            AppActions.bind(services)
            let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(),
                                              fileURL: file, managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            self.settings = settings
            services.settings = settings
            await settings.reload()

            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(
                #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: Self.tree())
            services.windows.ordersWindowsIn = false
            controller = try #require(services.windows.openWindow(workspaces: ["k1", "k2", "k3"], frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
            #expect(controller.state.profileID == .defaultProfile)
        }

        func write(_ json: String) async throws {
            try Data(json.utf8).write(to: url)
            await settings.reload()
        }

        func close() {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        /// The default space holds k1 and k4 (no window lists k4); Work holds k2 and k3.
        static func tree(pinned extra: [String: ProfileID] = [:]) -> DaemonTree {
            let keys = ["k1", "k2", "k3", "k4"]
            var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [])
            })
            tree.personal = PersonalState(
                sessions: [SessionRecord(id: "s-local")],
                profiles: [ProfileSnapshot(id: .defaultProfile, name: "Default", index: 0), ProfileSnapshot(id: work, name: "Work", index: 1)],
                pins: ["k2": work, "k3": work].merging(extra) { $1 }.sorted { $0.key < $1.key }
                    .map { WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $0.key), profile: $0.value) },
                workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
            return tree
        }
    }
}
