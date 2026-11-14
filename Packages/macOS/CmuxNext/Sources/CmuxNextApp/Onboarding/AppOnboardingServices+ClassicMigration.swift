import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOnboarding
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation

/// What one classic migration run did.
struct ClassicMigrationOutcome: Equatable {
    /// The daemon's decision for a launch's run; nil for a manual run.
    var decision: ClassicImportReply.Decision?
    var summary = ClassicImportSummary()
    /// False when the person declined the exact plan, or nobody answered it, before it wrote anything.
    var confirmed = true
    /// What the launch's run tells the person when it made nothing (a declined preview, a classic still open).
    var notice: String?
    /// The cmux-next workspaces it made, in order.
    var opened: [String] = []
    /// Why classic workspaces did not open, by classic key (the next manual run tries them again).
    var failures: [String: String] = [:]
}

/// The one-time migration from classic cmux (plans/cmux-next/classic-migration-DESIGN.md).
///
/// At launch, after restore, it brings classic's last saved session over once:
/// every window, its workspaces in sidebar order with their splits and tabs,
/// their groups, colors and pins. A ledger in cmux-next's own folder records
/// each workspace before, while and after it is made, so a run cut off midway
/// resumes without duplicates and a later launch makes nothing again. After a
/// downgrade to classic and a new upgrade, only workspaces classic made in
/// between come over. Classic's files are read and backed up, never changed.
extension AppOnboardingServices {
    /// This app's bundle id: the daemon keeps the ledger under
    /// `Application Support/cmux-next/<bundle id>/classic-migration`.
    var classicBundleID: String { services.environment.launch.bundleID ?? "com.cmuxterm.app.next" }

    /// Whether the launch runs the migration by itself: shipping builds yes;
    /// dev builds and test hosts only with `CMUX_NEXT_CLASSIC_MIGRATION=1`;
    /// `CMUX_NEXT_CLASSIC_MIGRATION=0` turns it off anywhere.
    var classicMigrationRunsAtLaunch: Bool {
        if let seam = owner.classicMigrationAtLaunch { return seam }
        switch ProcessInfo.processInfo.environment["CMUX_NEXT_CLASSIC_MIGRATION"] {
        case "0": return false
        case "1": return true
        default:
            let shipping = ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc", "com.cmuxterm.app.staging",
                            "com.cmuxterm.app.nightly.cmux-next"]
            return services.environment.launch.bundleID.map(shipping.contains) ?? false
        }
    }

    /// The launch's run: after restore, once per classic save. Never throws;
    /// a failure is logged and the ledger keeps what came over.
    ///
    /// - Parameter firstWorkspace: the workspace launch landed on for an empty
    ///   tree: a New Tab page workspace, closed when the migration brought workspaces
    ///   into its window, or Home, which stays.
    func migrateClassicAtLaunch(firstWorkspace: String?) async {
        guard classicMigrationRunsAtLaunch else { return }
        do {
            let outcome = try await migrateClassic(.automatic, firstWorkspace: firstWorkspace,
                                                   confirmation: confirmClassicImport)
            guard let notice = outcome.opened.isEmpty ? outcome.notice : owner.classicImportNotice else { return }
            ClassicImportStrings.toast(notice, in: services.windows.active?.window)
        } catch {
            services.daemon.logger.error("classic migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One migration run. Runs never overlap: a second one waits for the first. `progress`
    /// hears the share of the plan's classic workspaces handled (opened or left), 0...1.
    func migrateClassic(_ mode: ClassicImportMode, firstWorkspace: String? = nil,
                        confirmation: @escaping @MainActor (ClassicImportPreview) async -> ClassicImportAnswer,
                        progress: (@MainActor (Double) -> Void)? = nil) async throws -> ClassicMigrationOutcome {
        let previous = owner.classicMigrationRun
        let run = Task { @MainActor in
            _ = await previous?.result
            return try await runClassicMigration(mode, firstWorkspace: firstWorkspace, confirmation: confirmation, progress: progress)
        }
        owner.classicMigrationRun = run
        return try await run.value
    }

    /// The one confirmation path for launch and manual migration.
    func confirmClassicImport(_ preview: ClassicImportPreview) async -> ClassicImportAnswer {
        if let confirmation = owner.classicMigrationConfirmation { return await confirmation(preview) }
        return await ClassicImportConfirmation(preview: preview, services: services).ask()
    }

    /// The daemon's classic import operations on this Mac's connection.
    func classicImportClient() throws -> ClassicImportClient {
        guard let connection = services.daemon.connection else { throw DaemonError.notConnected }
        return ClassicImportClient(connection: connection, bundleID: classicBundleID)
    }

    private func runClassicMigration(_ mode: ClassicImportMode, firstWorkspace: String?,
                                     confirmation: @escaping @MainActor (ClassicImportPreview) async -> ClassicImportAnswer,
                                     progress: (@MainActor (Double) -> Void)?) async throws -> ClassicMigrationOutcome {
        // The daemon reads classic's save, the ledger and whether classic runs, and plans the run.
        let client = try classicImportClient()
        let reply = try await client.plan(mode)
        // The first contact on this Mac is recorded whatever happens, so a later
        // launch knows the tree was fresh then (and merges) rather than in use.
        let firstContact = mode == .automatic && reply.ledger == "none"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        var outcome = ClassicMigrationOutcome(decision: reply.decision)
        switch mode {
        case .automatic:
            // cmux-next was in use before this build (the tree had workspaces of the
            // person's own): it may already hold classic's work, moved by hand or by
            // the import action. The first run only records classic's workspaces as
            // seen; later classic saves still merge, and the action brings any back.
            if firstContact, firstWorkspace == nil {
                try await client.record(.baseline)
                outcome.decision = ClassicImportReply.Decision(decision: "skip", reason: "in_use_before")
                // Classic's workspaces were only recorded: say so once, and where to bring them.
                var local = reply.plan
                if local == nil { local = try await client.plan(.manual, outline: true).plan }
                if local?.workspaces.isEmpty == false {
                    outcome.notice = ClassicImportStrings.inUseBefore
                    owner.classicImportNotice = outcome.notice
                }
                return outcome
            }
            if reply.decision?.skips ?? true {
                if firstContact {
                    try await client.record(.seen)
                    // The first launch beside an open classic says why nothing came over, once.
                    if reply.decision?.reason == "classic_running", let bundle = reply.sourceBundleID {
                        outcome.notice = ClassicImportStrings.classicOpen(ClassicImportStrings.appName(bundle))
                        owner.classicImportNotice = outcome.notice
                    }
                }
                if let error = reply.error { throw ClassicMigrationFailure.daemon(error) }
                return outcome
            }
        case .manual:
            // A newer cmux-next's ledger, an unreadable one or an unreadable save: nothing runs.
            if let error = reply.error { throw ClassicMigrationFailure.daemon(error) }
        }
        guard let plan = reply.plan, let source = reply.source else {
            outcome.decision = ClassicImportReply.Decision(decision: "skip", reason: "no_classic_session")
            return outcome
        }
        outcome.summary.leftCloudVMs = !plan.cloudVMKeys.isEmpty
        outcome.summary.alreadyHere = plan.alreadyMigrated
        guard !plan.isEmpty else {
            // Asking by hand with nothing left to bring still takes back a launch's No.
            try await client.record(.finish(source: source, cloudVMKeys: plan.cloudVMKeys, appVersion: appVersion))
            return outcome
        }

        let preview = ClassicImportPreview(reply: reply)
        switch await confirmation(preview) {
        case .accepted:
            break
        case .declined:
            outcome.confirmed = false
            // The launch's No is kept: later launches stop asking. Import Workspaces from Classic cmux still runs.
            // A declined resume ends too (its half-made workspaces close on the next manual run).
            guard mode == .automatic else { return outcome }
            try await client.record(.decline(source: source))
            outcome.notice = ClassicImportStrings.declined
            owner.classicImportNotice = outcome.notice
            return outcome
        case .unanswered:
            outcome.confirmed = false
            // Recorded as contact without a save read, so the next launch asks again rather than taking
            // its own New Tab page for a tree in use and only recording classic's workspaces.
            if firstContact { try await client.record(.seen) }
            return outcome
        }

        // The daemon backs up the classic files this run read before anything changes here.
        try await client.record(.begin(source: source, backups: reply.backups, cloudVMKeys: plan.cloudVMKeys, appVersion: appVersion))

        // A cut-off run's half-made workspaces close before they are made again.
        let store = services.daemon.store
        if let connection = services.daemon.connection {
            for half in plan.cleanup {
                guard let key = store.workspace(id: half)?.key else { continue }
                _ = try? await connection.closeWorkspace(key, endTerminals: true)
            }
        }
        let groups = await makeClassicGroups(plan.groups, client: client)

        let windows = services.windows
        let firstWindow = firstWorkspace.flatMap { windows.registry.value.owner(of: $0) } ?? windows.active?.state.id
        // Every SSH host starts connecting now, all together. A workspace whose
        // host is not up when its turn comes is made after the local ones, so a
        // host that is off (a laptop away from its network) holds back nothing.
        let knownMachines = Set(services.machines.ssh.map(\.machineID))
        var connecting: [String: DaemonService] = [:]
        for saved in plan.workspaces {
            guard let remote = saved.remote, connecting[remote.sshDestination] == nil else { continue }
            connecting[remote.sshDestination] = try? startClassicDaemon(for: remote)
        }
        let hosts = connecting
        let run = ClassicMigrationRunState(
            client: client, outcome: outcome, mode: mode, plan: plan, groups: groups, hosts: hosts, progress: progress,
            targets: plan.windows.indices.map { $0 == 0 ? windows.targetWindow(preferring: firstWindow) : UUID().uuidString.lowercased() })

        // One window after another: creating windows side by side was five
        // times slower on the fleet (0.6 against 3 workspaces a second at 512).
        var later: [ClassicWorkspaceTurn] = []
        for index in plan.windows.indices { later += try await makeClassicWindow(index, run: run) }
        if !later.isEmpty {
            // The hosts still connecting, waited for together (each within its connect limit).
            let waiting = Set(later.compactMap { $0.saved.remote?.sshDestination })
            let waits = waiting.compactMap { destination in
                hosts[destination].map { daemon in Task { @MainActor in (destination, (try? await self.connected(daemon)) != nil) } }
            }
            for wait in waits {
                let (destination, up) = await wait.value
                guard !up else { continue }
                run.unreachable.insert(destination)
                // A machine this run added and that never connected is not left in the list.
                if let daemon = hosts[destination], !knownMachines.contains(daemon.machineID),
                   let session = services.machines.sshSession(daemon.machineID) {
                    await services.ssh.forget(session)
                }
            }
            for turn in later.sorted(by: { $0.index < $1.index }) { try await makeClassicWorkspace(turn.saved, window: turn.index, run: run) }
        }
        outcome = run.outcome
        let lastError = run.lastError, reveal = run.reveal, openedInFirstWindow = run.openedInFirstWindow
        try await client.record(.finish(source: nil, cloudVMKeys: [], appVersion: appVersion))
        // One workspace that did not open is logged; none opening is the run's failure.
        if outcome.opened.isEmpty, let lastError { throw lastError }
        // Set within the run, so whoever awaits the run reads it.
        if mode == .automatic, !outcome.opened.isEmpty { owner.classicImportNotice = ClassicImportStrings.notice(outcome.summary) }

        if let reveal { _ = windows.reveal(workspaceID: reveal) }
        // The New Tab page launch made for an empty tree gives way to classic's workspaces. A first
        // launch that landed on Home (FirstWorkspaceLaunch) made none: Home stays.
        if openedInFirstWindow, let firstWorkspace, let made = store.workspace(id: firstWorkspace), made.kind != "home",
           let key = made.key, let connection = services.daemon.connection {
            _ = try? await connection.closeWorkspace(key, endTerminals: true, ifEmpty: false)
        }
        return outcome
    }

    /// One classic window's workspaces, in order; returns the SSH ones whose
    /// host was not up at their turn, for after the local ones.
    fileprivate func makeClassicWindow(_ index: Int, run: ClassicMigrationRunState) async throws -> [ClassicWorkspaceTurn] {
        var waiting: [ClassicWorkspaceTurn] = []
        for saved in run.plan.windows[index].workspaces {
            if let remote = saved.remote, let host = run.hosts[remote.sshDestination], host.connection == nil {
                waiting.append(ClassicWorkspaceTurn(index: index, saved: saved))
                continue
            }
            try await makeClassicWorkspace(saved, window: index, run: run)
        }
        return waiting
    }

    /// Makes one classic workspace, recording it in the ledger before, while and after.
    fileprivate func makeClassicWorkspace(_ saved: ClassicSessionWorkspace, window index: Int, run: ClassicMigrationRunState) async throws {
        defer { run.handled() }
        let window = run.plan.windows[index]
        let frame = index == 0 ? nil : window.frame.flatMap(Self.onScreen)
        let client = run.client
        try await client.record(.workspace(key: saved.key, stage: .pending))
        var made: String?
        // This call's own copies, merged after: nothing holds the run's state across a suspension.
        var summary = ClassicImportSummary()
        var unreachable = run.unreachable
        defer {
            run.outcome.summary.merge(summary)
            run.unreachable.formUnion(unreachable)
        }
        // One the window did not show comes over unshown (a quiet claim): no view attaches its terminals, so they park.
        let scope = saved.key == window.selectedKey ? ActionRunScope.current : ActionRunScope(origin: .user, allowsViewChange: false)
        do {
            made = try await ActionRunScope.$current.withValue(scope) { // concurrency-allow: the async overload binds inside this run's task
                try await importClassicWorkspace(saved, into: run.targets[index], frame: frame, summary: &summary,
                                                 unreachable: &unreachable,
                                                 on: saved.remote.flatMap { run.hosts[$0.sshDestination] }) { id in
                    _ = try? await client.record(.workspace(key: saved.key, stage: .created, nextWorkspace: id))
                }
            }
        } catch {
            // Stays pending with its half-made workspace: the next manual run closes and remakes it.
            run.lastError = error
            run.outcome.failures[saved.key] = String(describing: error)
            return
        }
        // Nothing came over (an SSH host that did not connect): the next manual run tries again.
        guard let made else { return }
        await applyClassicIdentity(saved, to: made, groups: run.groups)
        try await client.record(.workspace(key: saved.key, stage: .done, nextWorkspace: made))
        run.outcome.opened.append(made)
        // The launch's run only: Import from Classic is the person asking now, its terminals open live.
        if run.mode == .automatic, saved.key != window.selectedKey { await parkClassicTerminals(of: made, saved: saved) }
        if index == 0 { run.openedInFirstWindow = true }
        if index == 0, saved.key == window.selectedKey { run.reveal = made }
    }

    /// Parks the terminals of a workspace that came over in the background (`park-tabs`): their shells end and their
    /// tabs stay, each starting when the workspace is first shown (`DaemonService.wakeParkedTabs`), so a session with more
    /// terminals than macOS has PTYs comes over whole. Classic scrollback keeps its shell running (it prints at the prompt).
    /// Every tab the daemon lists goes, with no wait for each to run: `park-tabs` leaves pages and ended terminals.
    private func parkClassicTerminals(of id: String, saved: ClassicSessionWorkspace) async {
        let local = services.machines.local
        guard local.supports(DaemonCapability.tabPark.rawValue), local.supports(DaemonCapability.tabRestartKeptLayout.rawValue),
              saved.remote == nil, !saved.layout.tabs.contains(where: { $0.scrollback != nil || $0.agent != nil }),
              saved.layout.tabs.contains(where: { $0.url == nil }), let connection = local.connection else { return }
        do {
            guard let shape = try await local.shape(of: WorkspaceKey(rawValue: id), after: connection) else { return }
            _ = try await connection.request(ParkTabsRequest(surfaces: shape.screens.flatMap(\.panes).flatMap(\.surfaces)))
        } catch {
            services.daemon.logger.error("classic workspace not parked: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether `ready` holds, now or within 5 s, woken by the store's own changes.
    private static func awaitStore(_ ready: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if ready() { return true }
        let outcome = FirstOutcome<Bool>()
        let watch = Task { @MainActor in
            for await done in ObservationStream(ready) where done {
                outcome.resolve(true)
                return
            }
        }
        // A bounded wait: the daemon's event normally lands within one turn.
        let bound = DemandTimer(owner: "ClassicMigration.awaitStore")
        bound.schedule(after: .seconds(5)) { outcome.resolve(false) }
        let done = await outcome.value()
        watch.cancel()
        bound.cancel()
        return done || ready()
    }

    /// Makes the plan's new groups (reusing ones an earlier run made) and
    /// returns cmux-next group ids by classic group id. Needs the daemon's
    /// state resources; on an older daemon workspaces come over loose.
    private func makeClassicGroups(_ groups: [ClassicMigrationPlan.Group], client: ClassicImportClient) async -> [String: WorkspaceGroupID] {
        var made: [String: WorkspaceGroupID] = [:]
        let local = services.machines.local
        guard let connection = local.connection, local.store.servesStateResources else { return [:] }
        for group in groups {
            if let existing = group.existing {
                made[group.classic.id] = WorkspaceGroupID(rawValue: existing)
                continue
            }
            do {
                let name = SidebarGroup.named(group.classic.name)
                let id = try await connection.state.createWorkspaceGroup(name: name, room: nil, color: group.classic.color).id
                try await client.record(.group(classic: group.classic.id, next: id))
                made[group.classic.id] = WorkspaceGroupID(rawValue: id)
                let icon = local.supports(DaemonCapability.workspaceGroupIcon.rawValue) ? group.classic.icon : nil
                let pinned: Bool? = local.supports(DaemonCapability.workspaceGroupPin.rawValue) && group.classic.pinned ? true : nil
                if group.classic.collapsed || icon != nil || pinned != nil {
                    try await connection.state.updateWorkspaceGroup(id, collapsed: group.classic.collapsed ? true : nil,
                                                                    icon: icon.map { .set($0) } ?? .unchanged, pinned: pinned)
                }
            } catch {
                services.daemon.logger.error("classic group not made: \(String(describing: error), privacy: .public)")
            }
        }
        return made
    }

    /// The workspace's classic color, pin and group, on its new cmux-next workspace.
    fileprivate func applyClassicIdentity(_ saved: ClassicSessionWorkspace, to id: String, groups: [String: WorkspaceGroupID]) async {
        let local = services.machines.local
        let store = local.store
        // The create returns before the store mirrors the new workspace: its look would be dropped.
        guard await Self.awaitStore({ store.workspace(id: id)?.key != nil }),
              let connection = local.connection, let key = store.workspace(id: id)?.key else {
            services.daemon.logger.error("classic workspace look not kept: \(id, privacy: .public) never showed")
            return
        }
        do {
            if let color = saved.color {
                try await connection.state.setWorkspaceIdentity(key, resource: store.stateResourceID(workspace: key), color: .set(color))
            }
            if saved.pinned, local.supports(DaemonCapability.workspacePin.rawValue) {
                _ = try await connection.setWorkspaceMetadata(key, pinned: true)
            }
            if let session = store.registryID, store.servesStateResources, case let group = saved.groupID.flatMap({ groups[$0] }) {
                try await connection.state.placePersonalWorkspace(session: session, key: key, resource: store.personalStateID(session: session, key: key), group: group.map { .set($0) } ?? .clear,
                                                                  index: group.flatMap { store.personal.index(afterLastMemberOf: $0, moving: key.rawValue, session: session) })
                await local.appliedThroughReply(on: connection, after: "classic group") // the next member's index reads this row (#28425); a loose one always leaves its create's group (#37161): the store can trail that row
            }
        } catch {
            services.daemon.logger.error("classic workspace look not kept: \(String(describing: error), privacy: .public)")
        }
    }

    /// `frame` when some screen shows most of it, else nil (the window opens at the default place).
    private static func onScreen(_ frame: CGRect) -> CGRect? {
        NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= min(200, frame.width) } ? frame : nil
    }
}

private enum ClassicMigrationFailure: Error {
    /// The daemon read no plan: an unreadable save, or a ledger from a newer cmux-next or one it could not read.
    case daemon(String)
}

extension OnboardingService {
    /// The local folders of classic's saved workspaces that Import Workspaces from Classic cmux
    /// would open (an SSH or Cloud VM workspace's are another machine's), for new agent tabs.
    /// Empty when the daemon is not up within its connect wait or has no classic save.
    func classicProjectFolders() async -> [String] {
        let onboarding = AppOnboardingServices(owner: self)
        do {
            _ = try await onboarding.connected(services.daemon)
            guard let plan = try await onboarding.classicImportClient().plan(.manual, outline: true).plan else { return [] }
            return plan.workspaces.filter { $0.remote == nil && $0.cloudVM == nil }.flatMap { workspace in
                [workspace.workingDirectory] + workspace.layout.tabs.compactMap(\.workingDirectory)
            }
        } catch {
            services.daemon.logger.error("classic folders not read: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
