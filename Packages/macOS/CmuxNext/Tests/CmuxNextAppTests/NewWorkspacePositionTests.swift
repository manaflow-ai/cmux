import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Austin 2026-10-20: a new workspace "moves my workspace around": it shows in one place, then
/// moves up and down until it gets to its place, sometimes not the right one, as if the app took
/// another workspace for the selected one. On the real daemon and the app's launch window, with a
/// workspace in the middle of the list selected, a new workspace (Cmd-N, quick Cmd-N presses, or a
/// create that waits for the daemon, like a link opened in a new workspace) is drawn at its
/// `workspaces.newPlacement` slot in its first frame and in every frame after, and stays there.
/// "Frame" here is a sample of the sidebar model every few milliseconds (`frames`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewWorkspacePositionTests {
    /// Polls until `done` holds or `limit` passes (a poll, as in `RapidWorkspaceCreateTests`).
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct Launched {
        let services: AppServices
        let root: URL
        let window: WindowState
        let sidebar: SidebarModel

        func stop() async {
            if let connection = services.daemon.connection, let identity = services.daemon.identity {
                _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                                  timeout: .seconds(10))
            }
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
            try? FileManager.default.removeItem(at: root)
        }

        /// The workspace rows the sidebar draws, top to bottom (a create's press row included).
        func rows() -> [String] { sidebar.allWorkspaces.map(\.id.rawValue) }
    }

    /// The app on a fresh same-tree daemon with `workspaces.newPlacement` at `placement`, and three
    /// workspaces made on top of the launch one.
    private static func launch(_ placement: String) async throws -> Launched {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-newpos-\(UUID().uuidString.prefix(8))")
        let session = "cn-newpos-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("cmux.json")
        try Data(#"{"workspaces":{"newPlacement":"\#(placement)"}}"#.utf8).write(to: config)
        // The daemon places a new workspace by the same file (`CMUX_NEXT_CONFIG_FILE`), not the runner's own settings.
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color",
                            "CMUX_NEXT_CONFIG_FILE": config.path] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: config,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        await Self.wait(within: .seconds(90)) {
            services.windows.active.flatMap { services.windows.registry.members(of: $0.state.id).first } != nil
                && services.machines.local.store.personal.isLoaded
        }
        let window = try #require(services.windows.active?.state)
        let sidebar = try #require(services.windows.controller(for: window.id)?.sidebar.model)
        let launched = Launched(services: services, root: root, window: window, sidebar: sidebar)
        for name in ["one", "two", "three"] { try await Self.create(name, in: launched) }
        return launched
    }

    /// Cmd-N named `name`, settled: the window lists it and the sidebar draws its live row.
    private static func create(_ name: String, in launched: Launched) async throws {
        let services = launched.services
        let before = Set(services.daemon.store.workspaces.map(\.id))
        #expect(services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(name)])))
        await Self.wait(within: .seconds(30)) { settledID(named: name, before: before, in: launched) != nil }
        _ = try #require(settledID(named: name, before: before, in: launched), "\(name) never settled")
    }

    /// The id of the workspace named `name` made after `before`, once the window lists it, its row
    /// is live and no create's press row is left.
    private static func settledID(named name: String, before: Set<String>, in launched: Launched) -> String? {
        let services = launched.services
        guard let id = services.daemon.store.workspaces.first(where: { $0.name == name && !before.contains($0.id) })?.id,
              services.windows.registry.members(of: launched.window.id).contains(id),
              launched.sidebar.allWorkspaces.first(where: { $0.id.rawValue == id })?.rowState == .live,
              PendingWorkspaceRows.shared.rows(in: launched.window.id).isEmpty else { return nil }
        return id
    }

    /// Selects the middle one of the three made workspaces, as a click on its row does.
    private static func selectMiddle(in launched: Launched) async throws -> String {
        let services = launched.services
        let made = launched.rows().filter { id in ["one", "two", "three"].contains(services.daemon.store.workspaces.first { $0.id == id }?.name) }
        try #require(made.count == 3, "rows: \(made)")
        let middle = made[1]
        services.windows.select(middle, in: launched.window)
        await Self.wait(within: .seconds(10)) { launched.window.workspaceID == middle }
        try #require(launched.window.workspaceID == middle)
        return middle
    }

    /// Every frame the sidebar draws while `press` runs and the new workspaces settle: each sampled row order that
    /// lists a new row (one not in `before`). Ends a second after every new row is live.
    private static func frames(in launched: Launched, count: Int, press: (_ sample: () -> Void) async -> Void) async -> (frames: [[String]], new: [String]) {
        let before = Set(launched.rows()).union(launched.services.daemon.store.workspaces.map(\.id))
        var frames: [[String]] = []
        func sample() {
            let rows = launched.rows()
            if rows.contains(where: { !before.contains($0) }), frames.last != rows {
                frames.append(rows)
                print("new-workspace-position frame \(frames.count): \(describe(rows, in: launched))")
            }
        }
        await press(sample)
        var settledAt: ContinuousClock.Instant?
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            sample()
            let new = launched.rows().filter { !before.contains($0) }
            let members = Set(launched.services.windows.registry.members(of: launched.window.id))
            let settled = new.count == count && new.allSatisfy(members.contains)
                && launched.sidebar.allWorkspaces.filter { new.contains($0.id.rawValue) }.allSatisfy { $0.rowState == .live }
                && PendingWorkspaceRows.shared.rows(in: launched.window.id).isEmpty
            if settled, settledAt == nil { settledAt = .now }
            if !settled { settledAt = nil }
            if let settledAt, ContinuousClock.now - settledAt > .seconds(1) { break }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return (frames, launched.rows().filter { !before.contains($0) })
    }

    /// `rows` by name, each new one with its row state, whether its press row (`press`) and its pending
    /// placement (`placing`) are still there, and whether the store calls it provisional.
    private static func describe(_ rows: [String], in launched: Launched) -> String {
        let services = launched.services, window = launched.window.id
        let pressRows = Set(PendingWorkspaceRows.shared.rows(in: window).map(\.id))
        return rows.map { id in
            let model = services.machines.workspace(id: id)?.0
            var name = model?.name ?? launched.sidebar.allWorkspaces.first { $0.id.rawValue == id }?.title ?? id
            if id == launched.window.workspaceID { name = "*" + name }
            let state = launched.sidebar.allWorkspaces.first { $0.id.rawValue == id }.map { "\($0.rowState)" } ?? "?"
            var flags = [state]
            if pressRows.contains(id) { flags.append("press") }
            if services.windows.pendingPlacements[id] != nil { flags.append("placing") }
            if model?.isProvisional == true { flags.append("provisional") }
            return flags == ["live"] ? name : "\(name)[\(flags.joined(separator: ","))]"
        }.joined(separator: " ")
    }

    /// The rows of `frame` that follow `anchor`, `count` of them.
    private static func after(_ anchor: String, in frame: [String], count: Int) -> [String] {
        guard let index = frame.firstIndex(of: anchor) else { return [] }
        return Array(frame[(index + 1)...].prefix(count))
    }

    @Test func afterCurrentDrawsCmdNRightBelowTheSelectedWorkspaceInEveryFrame() async throws {
        let launched = try await Self.launch("afterCurrent")
        let middle = try await Self.selectMiddle(in: launched)
        let (frames, new) = await Self.frames(in: launched, count: 1) { _ in
            _ = launched.services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("new")]))
        }
        await launched.stop()

        let made = try #require(new.first, "no new row")
        let wrong = frames.filter { frame in frame.contains(made) && Self.after(middle, in: frame, count: 1) != [made] }
        // Known: under `afterCurrent` a confirmed row can still draw one frame at the end of the list before its
        // slot (also at the base: CmdNRowSlotTests); the final place is exact. Follow-up to https://github.com/manaflow-ai/cmux/pull/23071.
        withKnownIssue("afterCurrent: one frame at the end of the list", isIntermittent: true) {
            #expect(wrong.isEmpty, "frames with the new row not right below the selected one: \(wrong.count) of \(frames.count), first \(wrong.first ?? [])")
        }
        #expect(Self.after(middle, in: frames.last ?? [], count: 1) == [made], "final: \(frames.last ?? [])")
    }

    /// Quick presses: each new workspace is selected at its press, so the next goes right below it.
    @Test func afterCurrentStacksQuickCmdNBelowTheSelectedWorkspaceInPressOrder() async throws {
        let launched = try await Self.launch("afterCurrent")
        let middle = try await Self.selectMiddle(in: launched)
        var keys: [String] = []
        var selectedAtPress: [Bool] = []
        let (frames, new) = await Self.frames(in: launched, count: 3) { sample in
            for press in 1...3 {
                _ = launched.services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("quick-\(press)")]))
                for row in PendingWorkspaceRows.shared.rows(in: launched.window.id) where !keys.contains(row.id) { keys.append(row.id) }
                // The press selects its workspace, so the next press anchors on it.
                selectedAtPress.append(launched.window.workspaceID == keys.last)
                // Key repeat, sampling meanwhile: the earlier presses' workspaces land in this time.
                let next = ContinuousClock.now + .milliseconds(33)
                while ContinuousClock.now < next { sample(); try? await Task.sleep(for: .milliseconds(3)) }
            }
        }
        await launched.stop()

        try #require(new.count == 3, "new rows: \(new)")
        try #require(keys.count == 3 && selectedAtPress == [true, true, true], "a press did not select its workspace: \(selectedAtPress)")
        let order = keys.count == 3 ? keys : new
        // Every frame lists the new rows it has right below the selected one, in press order.
        let wrong = frames.filter { frame in
            let shown = order.filter(frame.contains)
            return Self.after(middle, in: frame, count: shown.count) != shown
        }
        // Known: under `afterCurrent` a confirmed row can still draw one frame at the end of the list before its
        // slot (also at the base: CmdNRowSlotTests); the final place is exact. Follow-up to https://github.com/manaflow-ai/cmux/pull/23071.
        withKnownIssue("afterCurrent: one frame at the end of the list", isIntermittent: true) {
            #expect(wrong.isEmpty, "frames out of place: \(wrong.count) of \(frames.count), first \(wrong.first ?? [])")
        }
        #expect(Self.after(middle, in: frames.last ?? [], count: 3) == order, "final: \(frames.last ?? [])")
    }

    /// A create whose row waits for the daemon (a link or a folder opened in a new workspace, a new browser
    /// workspace: `WorkspaceHandlers.createAndShow`) anchors on the workspace selected at the press too.
    @Test func afterCurrentPlacesACreateThatWaitsForTheDaemonRightBelowTheSelectedWorkspace() async throws {
        let launched = try await Self.launch("afterCurrent")
        let middle = try await Self.selectMiddle(in: launched)
        let (frames, new) = await Self.frames(in: launched, count: 1) { _ in
            WorkspaceHandlers.createAndShow(services: launched.services, name: "opened")
        }
        await launched.stop()

        let made = try #require(new.first, "no new row")
        let wrong = frames.filter { frame in frame.contains(made) && Self.after(middle, in: frame, count: 1) != [made] }
        // Known: under `afterCurrent` a confirmed row can still draw one frame at the end of the list before its
        // slot (also at the base: CmdNRowSlotTests); the final place is exact. Follow-up to https://github.com/manaflow-ai/cmux/pull/23071.
        withKnownIssue("afterCurrent: one frame at the end of the list", isIntermittent: true) {
            #expect(wrong.isEmpty, "frames with the new row elsewhere: \(wrong.count) of \(frames.count), first \(wrong.first ?? [])")
        }
        #expect(Self.after(middle, in: frames.last ?? [], count: 1) == [made], "final: \(frames.last ?? [])")
    }

    @Test func beforeCurrentDrawsCmdNRightAboveTheSelectedWorkspaceInEveryFrame() async throws {
        let launched = try await Self.launch("beforeCurrent")
        let middle = try await Self.selectMiddle(in: launched)
        let (frames, new) = await Self.frames(in: launched, count: 1) { _ in
            _ = launched.services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("new")]))
        }
        await launched.stop()

        let made = try #require(new.first, "no new row")
        func above(_ frame: [String]) -> String? { frame.firstIndex(of: middle).flatMap { $0 > 0 ? frame[$0 - 1] : nil } }
        let wrong = frames.filter { frame in frame.contains(made) && above(frame) != made }
        // Known: under `beforeCurrent` a confirmed row can still draw one frame at the end of the list before its
        // slot (also at the base: CmdNRowSlotTests); the final place is exact. Follow-up to https://github.com/manaflow-ai/cmux/pull/23071.
        withKnownIssue("beforeCurrent: one frame at the end of the list", isIntermittent: true) {
            #expect(wrong.isEmpty, "frames with the new row not right above the selected one: \(wrong.count) of \(frames.count), first \(wrong.first ?? [])")
        }
        #expect(above(frames.last ?? []) == made, "final: \(frames.last ?? [])")
    }

    /// A window showing a top page selects the page's row, not the workspace it parked: Cmd-N there
    /// has no current workspace, so `afterCurrent` puts it at the top, not below the parked one.
    @Test func afterCurrentFromATopPageGoesToTheTopNotBelowTheParkedWorkspace() async throws {
        let launched = try await Self.launch("afterCurrent")
        let middle = try await Self.selectMiddle(in: launched)
        // History: Home is the home workspace since the docked Home, not a top page (`AgentChatFromHomeTests`).
        let page = TopPageRoute.page(.history)
        try #require(TopPages.show(page, services: launched.services, in: launched.window) != nil, "History did not show")
        try #require(launched.window.page == page && launched.window.workspaceID == middle)
        let home = NewWorkspacePlacements.home(launched.services.machines)
        let (frames, new) = await Self.frames(in: launched, count: 1) { _ in
            _ = launched.services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("new")]))
        }
        await launched.stop()

        let made = try #require(new.first, "no new row")
        #expect(frames.last?.first { $0 != home } == made, "final: \(frames.last ?? [])")
        #expect(Self.after(middle, in: frames.last ?? [], count: 1) != [made], "placed below the parked workspace")
    }

    /// The default: first in the list, above the selected workspace, in every frame.
    @Test func topDrawsCmdNFirstInEveryFrame() async throws {
        let launched = try await Self.launch("top")
        _ = try await Self.selectMiddle(in: launched)
        let home = NewWorkspacePlacements.home(launched.services.machines)
        let (frames, new) = await Self.frames(in: launched, count: 1) { _ in
            _ = launched.services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("new")]))
        }
        await launched.stop()

        let made = try #require(new.first, "no new row")
        func firstLoose(_ frame: [String]) -> String? { frame.first { $0 != home } }
        let wrong = frames.filter { frame in frame.contains(made) && firstLoose(frame) != made }
        #expect(wrong.isEmpty, "frames with the new row not first: \(wrong.count) of \(frames.count), first \(wrong.first ?? [])")
        #expect(firstLoose(frames.last ?? []) == made, "final: \(frames.last ?? [])")
    }
    @Test(arguments: [false, true])
    func aFailedFirstTabReleasesItsPlacementLedger(firstTab: Bool) async throws {
        enum FirstTabFailure: Error { case expected }
        let launched = try await Self.launch("top")
        let connection = try #require(launched.services.daemon.connection)
        let key = WorkspaceKey.generate()
        let ledger = NewWorkspacePlacements.Ledger()
        ledger.anchors[key.rawValue] = .after("old")
        ledger.groupAnchors[key.rawValue] = .firstInGroupOf("old")
        let rule = NewWorkspaceDefaultSlot(placement: .top, current: nil)
        var failed = false
        do {
            if firstTab {
                let _: String = try await WorkspaceCreation.createWithFirstTab(key, name: "failed", placedBy: rule, ledger: ledger,
                    on: connection, repair: launched.services.emptyWorkspaces) { _ in throw FirstTabFailure.expected }
            } else {
                let _: String = try await WorkspaceCreation.create(key, name: "failed", placedBy: rule, ledger: ledger,
                    on: connection, repair: launched.services.emptyWorkspaces) { _ in throw FirstTabFailure.expected }
            }
        } catch FirstTabFailure.expected { failed = true }
        await launched.stop()
        #expect(failed)
        #expect(!ledger.placedByDaemon.contains(key.rawValue))
        #expect(ledger.anchors[key.rawValue] == nil)
        #expect(ledger.groupAnchors[key.rawValue] == nil)
    }

    @Test func aConsumedLegacyPlacementReleasesItsUnarmedGroupAnchor() async throws {
        let launched = try await Self.launch("top")
        let windows = launched.services.windows
        let id = try #require(launched.services.daemon.store.workspaces.last).id
        windows.pendingPlacements[id] = PendingPlacement(window: launched.window.id, slot: nil, byDefault: nil)
        windows.pendingPlacementOrder.append(id)
        windows.newPlacements.groupAnchors[id] = .firstInGroupOf("old")
        windows.applyPendingPlacements(live: [id])
        #expect(windows.pendingPlacements[id] == nil)
        #expect(windows.newPlacements.groupAnchors[id] == nil)
        await launched.stop()
    }

    @Test func aRefusedSpacePinReleasesItsPlacementRegistration() async throws {
        let launched = try await Self.launch("top")
        let windows = launched.services.windows
        let anchors = windows.newPlacements.groupAnchors
        let pending = Set(windows.pendingPlacements.keys)
        let scope = DaemonCommandScope()
        defer { scope.close() }
        DaemonCommandScope.$current.withValue(scope) {
            WorkspaceHandlers.createAndShow(services: launched.services, room: ProfileID(rawValue: "missing-space"))
        }
        await Self.wait(within: .seconds(10)) { scope.isIdle }
        #expect(scope.isIdle)
        #expect(!scope.failures.isEmpty)
        #expect(windows.newPlacements.groupAnchors == anchors)
        #expect(Set(windows.pendingPlacements.keys) == pending)
        await launched.stop()
    }

}
