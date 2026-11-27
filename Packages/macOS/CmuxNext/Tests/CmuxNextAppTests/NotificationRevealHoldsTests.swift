import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// "every agent-chat notification path shows exactly one macOS banner, and each click opens the right chat's tab"
/// (the notify-banner-click goal). The probe's burst-click and relaunch-click rows (run 46007715275, Nightly
/// 946de8ba): three windows on the default space, chats the daemon made (each in a workspace of its own, no
/// claim, so reconcile files them), a banner click reveals one in the window in front, and a later daemon delta's
/// selection repair ("reconcile-repair") put the window back on another chat. Every case here runs the real
/// reveal (`AppActionContext.reveal`, the banner's path) and then the deltas that follow a click.
@MainActor @Suite(.serialized, .closesItsWindows)
struct NotificationRevealHoldsTests {
    /// w0..w2: one per window; c0..c3: chats the daemon makes later.
    static let owners = ["w0", "w1", "w2"]
    static let chats = ["c0", "c1", "c2", "c3"]

    static func snapshot(_ keys: [String], selected: [String: Int] = [:]) -> DaemonTree {
        let workspaces = keys.enumerated().map { index, key in
            let raw = UInt64(100 + index * 10), pane = PaneID(rawValue: raw)
            var panel = PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: raw + 1)), TabSnapshot(surface: SurfaceID(rawValue: raw + 2))])
            panel.activeTab = selected[key] ?? 0
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key,
                                     screens: [ScreenSnapshot(id: ScreenID(rawValue: raw), layout: .leaf(pane), panes: [panel])])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: workspaces)
        tree.personal = PersonalState(sessions: [SessionRecord(id: "s-local")],
                                      workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
        return tree
    }

    static func services() throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: snapshot(owners))
        services.windows.ordersWindowsIn = false
        services.windows.isOnScreen = { _ in true }
        return services
    }

    static func open(_ workspaces: [String], _ services: AppServices) throws -> WindowController {
        try #require(services.windows.openWindow(id: UUID().uuidString.lowercased(), workspaces: workspaces,
                                                 frame: CGRect(x: 120, y: 120, width: 900, height: 600), incognito: false))
    }

    static func closeAll(_ services: AppServices) {
        for controller in services.windows.controllers {
            controller.teardown()
            controller.window?.close()
        }
    }

    /// Brings `controller` in front by the registry's recency (no key window: the probe keeps the Nightly behind Preview).
    static func front(_ controller: WindowController, _ services: AppServices) {
        services.windows.registry.apply { $0.activate(controller.state.id); return WindowRegistry.Changes() }
    }

    /// Three windows, then the daemon makes the chats: reconcile files them in the window in front (`chatsFront`).
    static func setUp(_ services: AppServices, chatsFront: Int = 0) throws -> [WindowController] {
        let windows = try owners.map { try open([$0], services) }
        front(windows[chatsFront], services)
        services.machines.local.store.apply(snapshot: snapshot(owners + chats))
        return windows
    }

    /// The banner click's reveal: `NotificationCenterService.open(surface:)` minus the 15 s wait.
    static func click(_ key: String, tab: Int = 1, _ services: AppServices) throws {
        let store = services.machines.local.store
        let workspace = try #require(store.workspaces.first { $0.key?.rawValue == key })
        let pane = try #require(workspace.screens.first?.panes.first)
        let surface = SurfaceID(rawValue: UInt64(100 + (owners + chats).firstIndex(of: key)! * 10) + UInt64(tab + 1))
        let located = try #require(services.notifications.locate(surface: surface, in: store))
        #expect(located.pane === pane)
        AppActionContext(services: services).reveal(located, front: true)
    }

    static func describe(_ services: AppServices) -> String {
        let registry = services.windows.registry.value
        return registry.windows.map { window in
            let shown = services.windows.controller(for: window.id)?.state.workspaceID ?? "nil"
            let key = { (id: String) in services.workspace(id: id)?.key?.rawValue ?? id }
            return "\(window.id.prefix(4)) shows \(key(shown)) lists \(window.workspaceIDs.map(key)) guests \(window.guests.map(key).sorted())"
        }.joined(separator: "; ")
    }

    static func id(_ key: String, _ services: AppServices) -> String? {
        services.machines.local.store.workspaces.first { $0.key?.rawValue == key }?.id
    }

    /// The deltas that follow a click: a reorder (Move to Top, the ack's reorder), a tab selection, a new chat.
    static func deltas(_ services: AppServices, selecting key: String) {
        let store = services.machines.local.store
        store.apply(snapshot: snapshot(Array((chats + owners).reversed()), selected: [key: 1]))
        store.apply(snapshot: snapshot(owners + chats, selected: [key: 1]))
        store.apply(snapshot: snapshot(owners + chats + ["c9"], selected: [key: 1]))
    }

    /// Each window in front clicks a chat each window lists or owns, then every delta: the window keeps the chat.
    @Test(arguments: [0, 1, 2])
    func aRevealedChatStaysShownAfterTheDeltas(front index: Int) throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let windows = try Self.setUp(services)
        Self.front(windows[index], services)
        for chat in Self.chats {
            try Self.click(chat, services)
            let target = try #require(services.windows.controllers.first { $0.state.workspaceID == Self.id(chat, services) }, "\(chat): \(Self.describe(services))")
            Self.deltas(services, selecting: chat)
            #expect(target.state.workspaceID == Self.id(chat, services), "\(chat) in front \(index): \(Self.describe(services))")
        }
    }

    /// The burst: every chat's banner clicked in turn with no delta between; each shows, never the one before.
    @Test(arguments: [0, 1, 2])
    func aBurstOfClicksShowsEachChat(front index: Int) throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let windows = try Self.setUp(services)
        Self.front(windows[index], services)
        for chat in Self.chats {
            try Self.click(chat, services)
            let shown = services.windows.controllers.contains { $0.state.workspaceID == Self.id(chat, services) }
            #expect(shown, "\(chat) not shown after its click: \(Self.describe(services))")
        }
        Self.deltas(services, selecting: Self.chats.last!)
        let last = Self.id(Self.chats.last!, services)
        #expect(services.windows.controllers.contains { $0.state.workspaceID == last }, "the last click lost to a delta: \(Self.describe(services))")
    }
}

/// The probe's cause: Spaces is off (#48355, the default) and each window shows its own space (New Window gave each
/// one), so a chat the daemon made (the default space) is listed by the window but not in its space. The click's
/// reveal selects it and pins it to the window's space (`WindowManager.pin`); the click's own read ack is a delta
/// that lands before the pin, and its selection repair ("reconcile-repair") put the window on the chat's neighbor,
/// for good (`landedPins` then found the window moved on). Each case clicks the chat's second tab.
@MainActor @Suite(.serialized, .closesItsWindows)
struct NotificationRevealBeforeItsPinTests {
    static let work = ProfileID(rawValue: "room-work")
    static let keys = ["w0", "c0", "c1", "c2", "c3"]

    /// w0 is pinned to Work; the chats are in no space but the default unless `pinned` names them.
    static func snapshot(pinned: [String] = []) -> DaemonTree {
        var tree = NotificationRevealHoldsTests.snapshot(keys)
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: [ProfileSnapshot(id: .defaultProfile, name: "Default", index: 0), ProfileSnapshot(id: work, name: "Work", index: 1)],
            pins: (["w0"] + pinned).sorted().map { WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $0), profile: work) },
            workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
        return tree
    }

    @MainActor final class Fixture {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory: URL
        var controller: WindowController!
        var store: DaemonStore { services.machines.local.store }
        var windows: WindowManager { services.windows }

        /// `restored`: the window opens listing every chat (a relaunch's restore); else the chats join it by reconcile.
        @MainActor init(restored: Bool) async throws {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appending(path: "cnc-reveal-pin-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "cmux.json")
            try Data("{}".utf8).write(to: file)
            let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(),
                                              fileURL: file, managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            services.settings = settings
            await settings.reload()
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(
                #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            services.windows.ordersWindowsIn = false
            services.windows.isOnScreen = { _ in true }
            store.apply(snapshot: restored ? NotificationRevealBeforeItsPinTests.snapshot() : NotificationRevealHoldsTests.snapshot(["w0"]).withPersonal(of: NotificationRevealBeforeItsPinTests.snapshot()))
            let listed = restored ? NotificationRevealBeforeItsPinTests.keys : ["w0"]
            controller = try #require(services.windows.openWindow(workspaces: listed.compactMap(id), frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
            controller.state.enterProfile(NotificationRevealBeforeItsPinTests.work)
            #expect(!windows.spacesOn)
            if !restored {
                store.apply(snapshot: NotificationRevealBeforeItsPinTests.snapshot())
                windows.reconcileMembership()
            }
        }

        @MainActor func id(_ key: String) -> String? { store.workspaces.first { $0.key?.rawValue == key }?.id }
        @MainActor var shown: String? { controller.state.workspaceID.flatMap { id in store.workspaces.first { $0.id == id }?.key?.rawValue } }

        /// A banner click on `key`'s second tab.
        @MainActor func click(_ key: String) throws {
            let index = try #require(NotificationRevealBeforeItsPinTests.keys.firstIndex(of: key))
            let surface = SurfaceID(rawValue: UInt64(100 + index * 10) + 2)
            let located = try #require(services.notifications.locate(surface: surface, in: store))
            #expect(located.workspace.key?.rawValue == key)
            AppActionContext(services: services).reveal(located, front: true)
        }

        /// A delta before any pin lands (the click's read ack): the same tree again, then its reconcile.
        @MainActor func delta(pinned: [String] = []) {
            store.apply(snapshot: NotificationRevealBeforeItsPinTests.snapshot(pinned: pinned))
            windows.reconcileMembership()
        }

        @MainActor func close() {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test(arguments: [false, true])
    func aClickedChatStaysShownThroughADeltaBeforeItsPin(restored: Bool) async throws {
        let fixture = try await Fixture(restored: restored)
        defer { fixture.close() }
        #expect(fixture.windows.registry.value.lists(try #require(fixture.id("c1")), in: fixture.controller.state.id), "setup: the window does not list c1")
        try fixture.click("c1")
        #expect(fixture.shown == "c1")
        fixture.delta()
        #expect(fixture.shown == "c1", "a delta before the pin moved the window to \(fixture.shown ?? "nil")")
        fixture.delta(pinned: ["c1"])
        #expect(fixture.shown == "c1", "the landed pin moved the window to \(fixture.shown ?? "nil")")
        #expect(fixture.windows.pinSelections.isEmpty)
    }

    @Test(arguments: [false, true])
    func aBurstOfClicksBeforeTheirPinsShowsTheLast(restored: Bool) async throws {
        let fixture = try await Fixture(restored: restored)
        defer { fixture.close() }
        var pinned: [String] = []
        for chat in ["c0", "c1", "c2", "c3"] {
            try fixture.click(chat)
            #expect(fixture.shown == chat, "\(chat) not shown after its click")
            fixture.delta(pinned: pinned) // the ack of this click; the pins of the clicks before landed
            #expect(fixture.shown == chat, "\(chat): a delta before its pin moved the window to \(fixture.shown ?? "nil")")
            pinned.append(chat)
        }
        fixture.delta(pinned: pinned)
        #expect(fixture.shown == "c3")
    }
}

extension DaemonTree {
    /// This tree with `other`'s personal state.
    func withPersonal(of other: DaemonTree) -> DaemonTree {
        var tree = self
        tree.personal = other.personal
        return tree
    }
}
