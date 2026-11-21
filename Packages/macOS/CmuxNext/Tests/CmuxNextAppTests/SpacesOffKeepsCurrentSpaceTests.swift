import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/48355: Spaces is off by default, and nothing makes or switches
/// spaces while it is. A person who was on a space other than the default when it turned off keeps that space:
/// the window still shows it with its workspaces and the workspace it had selected, and a new window opens there
/// too, never in the default space. The other spaces and their workspaces stay in the daemon, untouched.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SpacesOffKeepsCurrentSpaceTests {
    @Test func aPersonOnANonDefaultSpaceKeepsItsWorkspacesWhenSpacesTurnsOff() async throws {
        let fixture = try await Fixture(settings: #"{"sidebar":{"showSpaces":true}}"#)
        defer { fixture.close() }
        let windows = fixture.services.windows
        // Spaces on: the person works in Work, on its second workspace.
        windows.switchProfile(Fixture.work, in: fixture.state)
        windows.select("k3", in: fixture.state)
        #expect(fixture.state.profileID == Fixture.work)
        #expect(fixture.shown == ["k2", "k3"])

        // cmux.json loses the key (an upgrade to the default-off build): Spaces turns off.
        try await fixture.write("{}")
        #expect(!windows.spacesOn)
        #expect(fixture.state.profileID == Fixture.work, "Spaces off moved the window to \(fixture.state.profileID.rawValue)")
        #expect(fixture.state.workspaceID == "k3", "the selected workspace changed")
        #expect(fixture.shown == ["k2", "k3"], "the space's workspaces changed")
        #expect(fixture.store.profileIDs == [.defaultProfile, Fixture.work], "a space was removed")
        #expect(WindowProfiles.visible(["k1", "k2", "k3"], profile: .defaultProfile, machines: fixture.services.machines) == ["k1"],
                "the default space's workspace left it")
        #expect(fixture.services.windows.registry.value.window(fixture.state.id)?.guests.isEmpty != false, "a window lists another's workspaces")

        // Nothing switches away: not a direct switch, not Next Space, not a swipe's intent.
        windows.switchProfile(.defaultProfile, in: fixture.state)
        _ = fixture.services.registry.perform("space.previous")
        #expect(fixture.state.profileID == Fixture.work)
        // Picking the default space's workspace (palette, a notification, the CLI) brings it here; the window stays.
        windows.select("k1", in: fixture.state)
        #expect(fixture.state.profileID == Fixture.work, "picking a hidden space's workspace switched the window away")
        // Its pin (sent to the home daemon, which this fixture lacks) lands: Work lists it and the window shows it.
        windows.select("k2", in: fixture.state)
        windows.bringIntoShownSpace(["k1"], of: fixture.state, selecting: "k1")
        fixture.store.apply(snapshot: Fixture.tree(pinnedToWork: ["k1", "k2", "k3"]))
        windows.reconcileMembership()
        await fixture.until { fixture.state.workspaceID == "k1" }
        #expect(fixture.state.profileID == Fixture.work)
        #expect(fixture.shown == ["k1", "k2", "k3"], "the picked workspace does not list in the window's space")
        #expect(fixture.state.workspaceID == "k1", "the picked workspace is not shown once its pin landed")

        // Every way to make a space is off, with the reason a CLI or MCP caller reads.
        let registry = fixture.services.registry
        for id: ActionID in ["space.new", "space.newIncognito", "space.next", "space.switch", "workspace.moveToSpace", "browser.link.openInNewSpace"] {
            #expect(!registry.isAvailable(id), "\(id.rawValue) is still offered")
            #expect(registry.unavailableReason(for: id) == RoomStrings.spacesOff)
        }
        #expect(registry.unavailableReason(for: "space.setTheme") == nil, "Settings edits the shown space's theme")
        #expect(!registry.perform("space.new"))
        #expect(fixture.store.profileIDs.count == 2)

        // A new window opens in the person's space, not the default one.
        #expect(windows.state(for: "w-new").profileID == Fixture.work)
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
            url = directory.appending(path: "cmux.json")
            try Data(json.utf8).write(to: url)
            AppActions.bind(services)
            settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(),
                                          fileURL: url, managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            services.settings = settings
            await settings.reload()

            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(
                #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: Self.tree())
            services.windows.ordersWindowsIn = false
            controller = try #require(services.windows.openWindow(workspaces: ["k1", "k2", "k3"], frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
            #expect(controller.state.profileID == .defaultProfile)
        }

        /// Waits until `condition` holds, observed (the select after a pin runs on a later main-actor turn); the
        /// bound only ends a failing wait.
        func until(_ condition: @escaping @MainActor @Sendable () -> Bool) async {
            let waiting = Task { for await done in ObservationStream({ condition() }) where done { break } }
            let bound = Task { try? await Task.sleep(for: .seconds(30)); waiting.cancel() }
            await waiting.value
            bound.cancel()
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

        /// The default space holds k1 (unless `pinnedToWork` names it); Work holds the rest.
        static func tree(pinnedToWork: [String] = ["k2", "k3"]) -> DaemonTree {
            let keys = ["k1", "k2", "k3"]
            var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [])
            })
            tree.personal = PersonalState(
                sessions: [SessionRecord(id: "s-local")],
                profiles: [ProfileSnapshot(id: .defaultProfile, name: "Default", index: 0), ProfileSnapshot(id: work, name: "Work", index: 1)],
                pins: pinnedToWork.map { WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $0), profile: work) },
                workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
            return tree
        }
    }
}
