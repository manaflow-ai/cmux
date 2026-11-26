import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextImportSuggestions
import CmuxNextOnboarding
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation

/// What one classic migration run did.
struct ClassicMigrationOutcome: Equatable {
    /// The daemon's decision for a launch's run; nil for a manual run.
    var decision: ClassicImportReply.Decision?
    var summary = ClassicImportSummary()
    /// False when the person declined the import or left the prompt unanswered.
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
        // Asked once per launch (Rust's rule and its list of shipping builds).
        ClassicMigrationRules.runsAtLaunch(seam: owner.classicMigrationAtLaunch,
                                           environment: ProcessInfo.processInfo.environment["CMUX_NEXT_CLASSIC_MIGRATION"],
                                           bundleID: services.environment.launch.bundleID)
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
                                                   confirmation: { await self.confirmClassicImport($0, atLaunch: true) })
            guard let notice = outcome.opened.isEmpty ? outcome.notice : owner.classicImportNotice else { return }
            let registry = services.registry
            ClassicImportStrings.toast(notice, in: services.windows.active?.window,
                                       importAgain: notice == ClassicImportPreviewStrings.notImported ? { _ = registry.perform("workspace.importClassic") } : nil)
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

    /// The one confirmation path for launch and manual migration. The launch's prompt says where the
    /// import waits, so its Not Now needs no toast after it.
    func confirmClassicImport(_ preview: ClassicImportPreview, atLaunch: Bool = false) async -> ClassicImportAnswer {
        if let confirmation = owner.classicMigrationConfirmation { return await confirmation(preview) }
        return await ClassicImportConfirmation(preview: preview, services: services, atLaunch: atLaunch).ask()
    }

    /// The daemon's classic import operations on this Mac's connection.
    func classicImportClient() throws -> ClassicImportClient {
        guard let connection = services.daemon.connection else { throw DaemonError.notConnected }
        return ClassicImportClient(connection: connection, bundleID: classicBundleID)
    }

    private func runClassicMigration(_ mode: ClassicImportMode, firstWorkspace: String?,
                                     confirmation: @escaping @MainActor (ClassicImportPreview) async -> ClassicImportAnswer,
                                     progress: (@MainActor (Double) -> Void)?) async throws -> ClassicMigrationOutcome {
        let client = try classicImportClient()
        let probe = try await client.probe(mode)
        let firstContact = mode == .automatic && probe.ledger == "none"
        var outcome = ClassicMigrationOutcome(decision: probe.decision)
        if let error = probe.error { throw ClassicMigrationFailure.daemon(error) }
        if firstContact, firstWorkspace == nil {
            // Record only the identity of the save beside an existing NEXT workspace tree.
            try await client.record(.baseline, observed: probe.observed)
            outcome.decision = ClassicImportReply.Decision(decision: "skip", reason: "in_use_before")
            if probe.available {
                outcome.notice = ClassicImportStrings.inUseBefore
                owner.classicImportNotice = outcome.notice
            }
            return outcome
        }
        // A manual import may discover an old tagged palette domain whose name cannot be
        // known without listing Preferences. Enumerating it requires the same consent.
        guard mode == .manual || (probe.available && probe.decision?.skips == false) else {
            if firstContact { try await client.record(.seen) }
            return outcome
        }

        switch await confirmation(ClassicImportPreview(reply: probe)) {
        case .accepted:
            break
        case .declined:
            outcome.confirmed = false
            guard mode == .automatic else { return outcome }
            try await client.record(.decline(source: nil))
            outcome.notice = ClassicImportPreviewStrings.notImported
            owner.classicImportNotice = outcome.notice
            return outcome
        case .unanswered:
            outcome.confirmed = false
            if firstContact { try await client.record(.seen) }
            return outcome
        }

        let reply: ClassicImportReply
        var settingsError: (any Error)?
        do {
            reply = try await client.planAfterConsent(mode)
            // A damaged settings source can be retried independently of saved workspaces.
            do {
                // The Swift settings merge uses the inline harness profiles this snapshot produces.
                try await client.record(.settings)
                try await owner.importClassicSettings?()
            } catch { settingsError = error }
            if let error = reply.error { throw ClassicMigrationFailure.daemon(error) }
        } catch {
            // The next launch must still know this tree was empty when first seen.
            if firstContact { try await client.record(.seen) }
            throw error
        }
        let restored = try await restoreClassicWorkspaces(reply, client: client, mode: mode,
            firstContact: firstContact, firstWorkspace: firstWorkspace,
            observed: settingsError == nil ? probe.observed : nil, progress: progress)
        if let settingsError { throw settingsError }
        return restored
    }

    private func restoreClassicWorkspaces(_ reply: ClassicImportReply, client: ClassicImportClient,
                                          mode: ClassicImportMode, firstContact: Bool, firstWorkspace: String?,
                                          observed: String?, progress: (@MainActor (Double) -> Void)?) async throws -> ClassicMigrationOutcome {
        var outcome = ClassicMigrationOutcome(decision: reply.decision)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if reply.decision?.reason == "classic_running" {
            if firstContact { try await client.record(.seen) }
            if let bundle = reply.sourceBundleID {
                outcome.notice = ClassicImportStrings.classicOpen(ClassicImportStrings.appName(bundle))
                owner.classicImportNotice = outcome.notice
            }
            return outcome
        }
        guard let plan = reply.plan, let source = reply.source else {
            if reply.settingsOnly {
                try await client.record(.finish(source: nil, cloudVMKeys: [], appVersion: appVersion), observed: observed)
                outcome.summary.settingsOnly = true
                outcome.notice = ClassicImportStrings.settingsComplete
                owner.classicImportNotice = outcome.notice
            } else if reply.decision?.reason == "unchanged" || reply.decision?.reason == "no_classic_session" {
                try await client.record(.finish(source: reply.source, cloudVMKeys: [], appVersion: appVersion), observed: observed)
            } else if firstContact {
                try await client.record(.seen)
            }
            return outcome
        }
        owner.rememberClassicFolders(in: plan)
        outcome.summary.leftCloudVMs = !plan.cloudVMKeys.isEmpty
        outcome.summary.alreadyHere = plan.alreadyMigrated
        guard !plan.isEmpty else {
            try await client.record(.finish(source: source, cloudVMKeys: plan.cloudVMKeys, appVersion: appVersion), observed: observed)
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
                hosts[destination].map { daemon in Task<(String, Bool), Never> { @MainActor in (destination, (try? await self.connected(daemon)) != nil) } }
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
        try await client.record(.finish(source: nil, cloudVMKeys: [], appVersion: appVersion), observed: observed)
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
        let frame = index == 0 ? nil : window.frame(onScreens: NSScreen.screens.map(\.visibleFrame))
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
}

private enum ClassicMigrationFailure: Error {
    /// The daemon read no plan: an unreadable save, or a ledger from a newer cmux-next or one it could not read.
    case daemon(String)
}
