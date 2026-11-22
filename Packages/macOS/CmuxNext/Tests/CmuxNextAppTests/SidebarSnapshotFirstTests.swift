import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Observation
import Testing

/// Snapshot-first sidebar at launch (the P0 where the sidebar stayed blank
/// for seconds): a window draws the rows the app saved last time in its
/// first frame, before the daemon connects, and the live tree then updates
/// those rows in place. Measured on a fleet build before this change: with
/// no remembered daemon launch snapshot (every new tag) or a snapshot
/// without window records, the sidebar stayed empty until `server ensure`
/// plus the login-shell capture finished (4.3-5.5 s on a cold daemon).
/// Windows are never put on screen and the daemon never starts.
@MainActor @Suite struct SidebarSnapshotFirstTests {
    static let keys = (1...3).map { WorkspaceKey(rawValue: "7a1c2e3f-4b5d-4e6f-8a9b-0c1d2e3f4a5\($0)") }

    static func id(_ index: Int) -> String { keys[index - 1].rawValue }

    static func tempFile() -> SidebarSnapshotFile {
        SidebarSnapshotFile(url: FileManager.default.temporaryDirectory
            .appending(path: "sidebar-snapshot-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: SidebarSnapshotFile.fileName))
    }

    /// Last run's sidebar: one loose workspace and a group of two, in a
    /// window with two spaces.
    static func savedSnapshot() -> SidebarSnapshot {
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let sections = [SidebarSection(kind: .machine(local), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID(id(1)), title: "api-server", icon: .symbol("terminal"))),
            .group(SidebarGroup(id: GroupID("grp-work"), name: "Work", color: .blue, workspaces: [
                SidebarWorkspace(id: WorkspaceID(id(2)), title: "billing"),
                SidebarWorkspace(id: WorkspaceID(id(3)), title: "payments", icon: .emoji("💳")),
            ])),
        ])]
        let profiles = [SidebarProfile(id: ProfileKey("p-home"), name: "Home"), SidebarProfile(id: ProfileKey("p-work"), name: "Work")]
        return SidebarSnapshot(sections: sections, profiles: profiles, activeProfileID: ProfileKey("p-work"))
    }

    static func savedFile(window: String = "win-saved") throws -> SidebarSnapshotFile {
        let file = tempFile()
        var document = SidebarSnapshotDocument()
        document.record(savedSnapshot(), window: window)
        try file.write(document)
        return file
    }

    /// Services with their own `LaunchReveal` (a manual clock, so its
    /// deadline never fires on its own), never the app-wide one.
    static func services(file: SidebarSnapshotFile?, reveal: LaunchReveal = LaunchReveal(clock: ManualClock())) -> AppServices {
        _ = NSApplication.shared
        var environment = AppEnvironment.current([:])
        environment.sidebarSnapshotFile = file
        let services = AppServices(environment: environment, launchReveal: reveal)
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        return services
    }

    static func tree(_ indices: [Int]) -> DaemonTree {
        DaemonTree(workspaceRevision: 10, workspaces: indices.map { index in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index)), key: keys[index - 1], name: "w\(index)")
        })
    }

    static func rows(_ controller: WindowController) -> [SidebarWorkspace] {
        controller.sidebar.model.sections.flatMap(\.workspaces)
    }

    /// Waits a bounded number of main-actor turns (never wall time).
    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
    }

    static func closeAll(_ services: AppServices) {
        for controller in services.windows.controllers { controller.window?.close() }
    }

    @Test func aSavedSidebarShowsBeforeTheDaemonConnects() throws {
        let services = Self.services(file: try Self.savedFile())
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        // Same turn as the window: no await, the daemon never started.
        #expect(services.daemon.connection == nil)
        #expect(!services.daemon.store.isLoaded)
        let rows = Self.rows(controller)
        #expect(rows.map(\.id.rawValue) == [Self.id(1), Self.id(2), Self.id(3)])
        #expect(rows.map(\.title) == ["api-server", "billing", "payments"])
        #expect(rows.allSatisfy { $0.rowState == .stale })
        #expect(controller.sidebar.model.profiles.map(\.name) == ["Home", "Work"])
        #expect(controller.sidebar.model.activeProfileID == ProfileKey("p-work"))
        Self.closeAll(services)
    }

    /// The launch budget (about 300 ms to the first seeded row on a fleet
    /// build): counted in steps, not time. The rows are in the sidebar
    /// model when the window is presented, zero main-actor turns after the
    /// window was made, so its first frame draws them.
    @Test func seededRowsAreInTheSidebarWhenTheWindowIsPresented() throws {
        let services = Self.services(file: try Self.savedFile())
        var rowsAtPresent: Int?
        var readyAtPresent: Bool?
        services.windows.onPresent = { controller in
            rowsAtPresent = Self.rows(controller).count
            readyAtPresent = controller.sidebar.isReadyForReveal
        }
        services.windows.restoreWhenLoaded()
        #expect(rowsAtPresent == 3)
        #expect(readyAtPresent == true)
        Self.closeAll(services)
    }

    @Test func aLaunchSnapshotWithoutWindowRecordsListsEveryWorkspace() async throws {
        let services = Self.services(file: nil)
        // The daemon's launch snapshot had a tree but no window records.
        services.daemon.store.applyProvisional(snapshot: Self.tree([1, 2, 3]))
        #expect(services.daemon.launchSnapshotWindows == nil)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        #expect(services.windows.registry.members(of: controller.state.id) == [Self.id(1), Self.id(2), Self.id(3)])
        await Self.settle { Self.rows(controller).count == 3 }
        #expect(Self.rows(controller).map(\.id.rawValue) == [Self.id(1), Self.id(2), Self.id(3)])
        #expect(Self.rows(controller).allSatisfy { $0.rowState == .stale })
        Self.closeAll(services)
    }

    @Test func liveDataUpdatesTheSavedRowsInPlace() async throws {
        let services = Self.services(file: try Self.savedFile())
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        let seeded = Self.rows(controller).map(\.id)
        #expect(seeded.count == 3)
        // Every sidebar state between the seed and the live rows: never empty.
        let states = SeenRows()
        let model = controller.sidebar.model
        let watch = Task { @MainActor in
            for await sections in Observations({ model.sections }) { states.rows.append(sections.flatMap(\.workspaces)) }
        }
        services.daemon.store.apply(snapshot: Self.tree([1, 2, 3]))
        await Self.settle { Self.rows(controller).allSatisfy { $0.rowState == .live } && !Self.rows(controller).isEmpty }
        watch.cancel()
        let live = Self.rows(controller)
        #expect(live.map(\.id) == seeded)
        #expect(live.allSatisfy { $0.rowState == .live })
        #expect(live.map(\.title) == ["w1", "w2", "w3"])
        #expect(states.rows.allSatisfy { !$0.isEmpty }, "the sidebar went blank between the saved and the live rows")
        Self.closeAll(services)
    }

    /// Nothing saved: the loading local section shows placeholder rows,
    /// which offer no menu (never a workspace menu for an id the daemon
    /// does not know), while a saved row's menu is the workspace menu.
    @Test func aPlaceholderRowHasNoContextMenu() throws {
        let services = Self.services(file: nil)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        let placeholder = try #require(Self.rows(controller).first)
        #expect(placeholder.rowState == .placeholder)
        #expect(controller.sidebar.contextMenu(for: .workspaces([placeholder.id])) == nil)
        Self.closeAll(services)
    }

    /// A select intent for a placeholder (from any entry point) never
    /// reaches the window: no member, no shown workspace.
    @Test func aPlaceholderIdNeverBecomesAWindowMember() throws {
        let services = Self.services(file: nil)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        let placeholder = try #require(Self.rows(controller).first)
        #expect(placeholder.rowState == .placeholder)
        controller.sidebar.model.onIntent?(.select(placeholder.id))
        #expect(!services.windows.registry.members(of: controller.state.id).contains(placeholder.id.rawValue))
        #expect(controller.state.workspaceID != placeholder.id.rawValue)
        Self.closeAll(services)
    }

    /// After a crash left incognito workspaces (the ledger lists them), the
    /// launch snapshot without window records never shows every workspace:
    /// that would put incognito workspaces in a normal window.
    @Test func theEveryWorkspaceFallbackNeverShowsLeftoverIncognitoWorkspaces() throws {
        let services = Self.services(file: nil)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appending(path: "incognito-ledger-tests-\(UUID().uuidString).json")
        try Data(#"{"workspaces":["\#(Self.id(2))"]}"#.utf8).write(to: ledgerURL)
        services.windows.incognitoLedger = IncognitoWorkspaceLedger(url: ledgerURL)
        services.daemon.store.applyProvisional(snapshot: Self.tree([1, 2, 3]))
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        #expect(!services.windows.registry.members(of: controller.state.id).contains(Self.id(2)))
        #expect(!Self.rows(controller).contains { $0.id.rawValue == Self.id(2) })
        Self.closeAll(services)
    }

    /// An incognito window's sidebar is never saved.
    @Test func anIncognitoWindowIsNeverRecorded() async throws {
        let services = Self.services(file: Self.tempFile())
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        let window = controller.state.id
        services.windows.registry.apply { $0.markIncognito(window); return WindowRegistry.Changes() }
        services.daemon.store.apply(snapshot: Self.tree([1, 2, 3]))
        await Self.settle { !services.windows.registry.isLaunching }
        for _ in 0..<200 { await Task.yield() }
        await services.sidebarSnapshots.flush()
        #expect(await services.sidebarSnapshots.document.snapshot(for: window, fallback: false) == nil)
        Self.closeAll(services)
    }

    /// A sidebar with nothing saved stays clear (held for LaunchReveal)
    /// until its first live rows arrive, then comes in.
    @Test func theSidebarIsHeldUntilItsRowsArrive() async throws {
        let reveal = LaunchReveal(clock: ManualClock())
        let services = Self.services(file: nil, reveal: reveal)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        #expect(controller.sidebar.container.alphaValue == 0)
        #expect(!reveal.isReady(.sidebar))
        services.daemon.store.apply(snapshot: Self.tree([1, 2, 3]))
        await Self.settle { reveal.isReady(.sidebar) }
        #expect(reveal.isReady(.sidebar))
        #expect(controller.sidebar.container.alphaValue == 1)
        Self.closeAll(services)
    }

    /// Saved rows are real rows: the sidebar is ready in its first frame,
    /// never held.
    @Test func aSavedSidebarIsNeverHeld() throws {
        let reveal = LaunchReveal(clock: ManualClock())
        let services = Self.services(file: try Self.savedFile(), reveal: reveal)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        #expect(reveal.isReady(.sidebar))
        #expect(controller.sidebar.container.alphaValue == 1)
        Self.closeAll(services)
    }

    /// An unavailable daemon is a settled state: the sidebar comes in
    /// (with its connecting header) instead of waiting for the deadline.
    @Test func anUnavailableDaemonReleasesTheSidebar() async throws {
        let reveal = LaunchReveal(clock: ManualClock())
        let services = Self.services(file: nil, reveal: reveal)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        #expect(!reveal.isReady(.sidebar))
        services.daemon.noteStartupFailure(.unsupportedProtocol(11))
        await Self.settle { reveal.isReady(.sidebar) }
        #expect(reveal.isReady(.sidebar))
        #expect(controller.sidebar.container.alphaValue == 1)
        Self.closeAll(services)
    }

    /// Without any signal, the reveal deadline (injected clock, no wall
    /// time) still brings the held sidebar in.
    @Test func theDeadlineReleasesAHeldSidebarWithoutASignal() async throws {
        let clock = ManualClock()
        let reveal = LaunchReveal(clock: clock, deadline: .milliseconds(1500))
        let services = Self.services(file: nil, reveal: reveal)
        services.windows.restoreWhenLoaded()
        let controller = try #require(services.windows.controllers.first)
        // Held, so the deadline is armed (else waiting for it never ends).
        try #require(controller.sidebar.container.alphaValue == 0)
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .milliseconds(1500))
        await Self.settle { reveal.isReady(.sidebar) }
        #expect(reveal.isReady(.sidebar))
        #expect(controller.sidebar.container.alphaValue == 1)
        Self.closeAll(services)
    }
}

/// Every row list one sidebar model went through.
@MainActor private final class SeenRows {
    var rows: [[SidebarWorkspace]] = []
}
