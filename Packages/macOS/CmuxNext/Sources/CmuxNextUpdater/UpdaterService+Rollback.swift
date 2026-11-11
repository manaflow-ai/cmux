public import CmuxUpdater
public import Foundation
import CmuxNextWakeups

/// What a rollback compares, read off the main actor
/// (``UpdaterService/rollbackInputs(to:stateDirectories:)``).
nonisolated public struct RollbackInputs: Sendable {
    /// Kept versions, newest first, each with the schemas it reads (its
    /// Info.plist, its record, else its own CLI; nil when none says).
    public var kept: [KeptVersion]
    /// The newest schema each store holds; nil when they could not be read.
    public var stored: [String: Int]?

    public init(kept: [KeptVersion], stored: [String: Int]?) {
        self.kept = kept
        self.stored = stored
    }
}

/// Where the running bundle's keep for rollback is.
enum KeepState {
    case running, kept
}

/// Rollback (decision 2026-10-04): the running bundle is kept right before
/// each install, and a rollback runs only when the kept build reads every
/// store the daemons hold (`StoreSchemaProbe`, `app call updates.rollback`).
extension UpdaterService {
    /// Previous versions this app keeps (`updates.keepPreviousVersions`).
    public var keptVersions: KeptVersionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appending(path: "cmux-next/\(identity.bundleIdentifier ?? "cmux")/versions", directoryHint: .isDirectory)
        return KeptVersionStore(root: root, teamID: { UpdateDropBack.signingTeam(of: $0) },
                                quickTeamID: { UpdateDropBack.quickSigningTeam(of: $0) })
    }

    /// What is known about the running build when it is kept: its team (the running code's own,
    /// no file read), the stores it reads (its Info.plist; `schemas` from its CLI otherwise) and
    /// its build date, so going back to it checks none of that again.
    func runningRecord(schemas: [String: Int]? = nil) -> KeptRecord {
        let plist = (Bundle.main.object(forInfoDictionaryKey: "CmuxStoreSchemas") as? [String: Any])?
            .compactMapValues { ($0 as? NSNumber)?.intValue }
        return KeptRecord(build: identity.build, date: currentBuildNotes?.date, teamID: UpdateDropBack.runningTeam,
                          storeSchemas: plist ?? schemas)
    }

    /// An update staged: keep the running bundle for rollback now, off the
    /// main thread, so the click that installs does no disk work (the
    /// clone, and the prune's signature reads of every kept build, take
    /// seconds on a busy disk). Once per running build.
    func keepRunningBuildForRollback() {
        guard keptRunningBuild == nil else { return }
        keptRunningBuild = .running
        let store = keptVersions, bundle = Bundle.main.bundleURL, build = identity.build, limit = preferences.keepPreviousVersions
        let hasPlistSchemas = Bundle.main.object(forInfoDictionaryKey: "CmuxStoreSchemas") != nil
        let partialRecord = runningRecord()
        let log = log
        let work = work
        // task-owner: one clone that ends by itself; the install waits for nothing it does. The clone and the
        // prune's signature reads run on the files lane, best effort (nobody waits), and quit waits for them.
        keepTask = Task(priority: WorkPriority.bestEffort.taskPriority) { [weak self] in
            // The stores this build reads, from its own CLI when its Info.plist does not say: asked
            // now, so going back to it never waits on that probe.
            var record = partialRecord
            if !hasPlistSchemas { record.storeSchemas = await StoreSchemaProbe(bundle: bundle).readable() }
            let kept = (try? await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { [record] () -> Bool in
                #if DEBUG || CMUX_BENCH_HOOKS
                UpdateHarness.mark("keep_previous_start")
                #endif
                defer {
                    #if DEBUG || CMUX_BENCH_HOOKS
                    UpdateHarness.mark("keep_previous_end")
                    #endif
                }
                do {
                    try store.keep(bundle: bundle, build: build, limit: limit, record: record)
                    log.append("kept \(build) for rollback when the update staged")
                    return true
                } catch {
                    log.append("could not keep \(build) for rollback: \(error)")
                    return false
                }
            }) ?? false
            self?.keptRunningBuild = kept ? .kept : nil
        }
    }

    /// Sparkle is about to replace the running bundle. The bundle was kept
    /// when the update staged; only a keep that never ran or failed runs
    /// here (a quit that installs an update staged before this launch).
    public func updaterWillInstallUpdate(build: String) {
        installingBuild = build
        guard keptRunningBuild == nil else { return }
        do {
            try keptVersions.keep(bundle: Bundle.main.bundleURL, build: identity.build, limit: preferences.keepPreviousVersions,
                                  record: runningRecord())
            log.append("kept \(identity.build) for rollback before installing \(build)")
        } catch {
            log.append("could not keep \(identity.build) for rollback: \(error)")
        }
    }

    /// Reads the kept versions and the stored schemas off the main actor: the
    /// list reads each kept build's Info.plist and record, and the stored
    /// schemas are one run of the running build's CLI per state root. Both at
    /// once. `stateDirectories` are the daemons' state roots (nil: cmux-tui's
    /// default).
    public func rollbackInputs(to build: String? = nil, stateDirectories: [URL?]) async -> RollbackInputs {
        let store = keptVersions
        let bundle = Bundle.main.bundleURL
        let work = work
        // task-owner: the rollback's read; awaited below.
        async let stored = StoreSchemaProbe(bundle: bundle).stored(stateDirectories: stateDirectories)
        var kept = (try? await work.run(.userVisible, mayBlock: .files) { store.list() }) ?? []
        // The build the rollback would take, when neither its Info.plist nor its record names its
        // schemas: its own CLI says. Only that one (each probe is a process start, seconds on a
        // busy Mac); a refusal or another kept build asks none.
        let target = build ?? RollbackDecision.previous(kept: kept, running: identity.build)?.build
        if let index = kept.firstIndex(where: { $0.build == target }), kept[index].storeSchemas == nil {
            kept[index].storeSchemas = await StoreSchemaProbe(bundle: kept[index].bundle).readable()
        }
        return RollbackInputs(kept: kept, stored: await stored)
    }

    /// Whether a rollback to `build` (nil: the previous build) would run.
    public func rollbackDecision(to build: String?, inputs: RollbackInputs) -> Result<KeptVersion, RollbackRefusal> {
        guard let stored = inputs.stored else { return .failure(.storesUnknown) }
        return RollbackDecision.decide(kept: inputs.kept, build: build, running: identity.build, stored: stored,
                                       teamID: UpdateDropBack.runningTeam)
    }
}

extension UpdaterService {
    /// Builds at or below this are not offered after a rollback.
    static let skipsBuildsThroughKey = "cmux.next.updates.skipsBuildsThrough"
    /// The build a rollback or Install this version went to: while it runs, a newer build waits
    /// for the person's click (``UpdateController/asksBeforeInstalling``); any other build clears it.
    static let pickedBuildKey = "cmux.next.updates.pickedBuild"

    /// Whether the running build is the one a rollback or Install this version went to, so a newer
    /// build waits for the person's click (the driver's hold, and ``applyDownloadPolicy()``'s resume).
    var runsPickedBuild: Bool { defaults.string(forKey: Self.pickedBuildKey) == identity.build }

    /// Puts `build` (nil: the previous build) in place of the running bundle when
    /// ``rollbackDecision`` allows it, and stops offering the build left behind. The swap runs on
    /// the files lane (it clones the running bundle). The caller relaunches
    /// (``UpdateDropBack/run(to:checkOnly:stateDirectories:)``).
    func swapForRollback(to build: String?, inputs: RollbackInputs) async throws -> KeptVersion {
        let target = try rollbackDecision(to: build, inputs: inputs).get()
        UpdateDropBack.mark("revert.decided")
        revert = RevertProgress(step: .swapping, target: target.build, label: RevertTarget(kept: target).label)
        let bundle = Bundle.main.bundleURL, current = identity.build, store = keptVersions
        let limit = preferences.keepPreviousVersions, record = runningRecord()
        try await work.run(.userVisible, mayBlock: .files) {
            try RollbackSwap.perform(current: bundle, currentBuild: current, target: target, store: store, limit: limit, record: record)
        }
        UpdateDropBack.mark("revert.swapped")
        defaults.set(identity.build, forKey: Self.skipsBuildsThroughKey)
        defaults.set(target.build, forKey: Self.pickedBuildKey)
        controller?.skipsBuildsThrough = identity.build
        log.append("rolled back \(identity.build) -> \(target.build)")
        return target
    }

    /// Restores the skip after a rollback at launch, and asks before installing while the build the
    /// person picked runs; once another build runs (they installed forward), updates install as set.
    /// Then puts back what a swap cut short left (``RollbackSwap/recover(current:store:)``) and reads
    /// the build Go back would take (``refreshRevertOffer()``), off the main thread.
    func restoreRollbackSkip() {
        controller?.skipsBuildsThrough = defaults.string(forKey: Self.skipsBuildsThroughKey)
        let picked = defaults.string(forKey: Self.pickedBuildKey)
        if picked != nil && picked != identity.build { defaults.removeObject(forKey: Self.pickedBuildKey) }
        controller?.asksBeforeInstalling = picked == identity.build
        let store = keptVersions, bundle = Bundle.main.bundleURL, log = log, work = work
        // task-owner: a launch tidy that ends by itself; nobody waits on it.
        Task(priority: WorkPriority.bestEffort.taskPriority) { [weak self] in
            let tidied = (try? await work.run(.bestEffort, mayBlock: .files) {
                RollbackSwap.recover(current: bundle, store: store) + store.sweep()
            }) ?? []
            if !tidied.isEmpty { log.append("rollback: tidied what a cut-short keep or swap left: \(tidied.joined(separator: ", "))") }
            await self?.refreshRevertOffer()
        }
    }

    /// The build Go back takes now, for the Updated card's and the menu's "Go back to <version>
    /// from <date>": the kept build this Mac came from; nil with none kept.
    public func refreshRevertOffer() async {
        let store = keptVersions, running = identity.build
        let kept = (try? await work.run(.bestEffort, mayBlock: .files) { store.list(teams: false) }) ?? []
        let target = RollbackDecision.previous(kept: kept, running: running).map(RevertTarget.init(kept:))
        if revertOffer != target { revertOffer = target }
    }

    /// The newest earlier build the feed still offers this Mac (switchable: not pulled, signed),
    /// by number: Go back's way when nothing is kept.
    func previousOfferedBuild() async -> String? {
        revert = RevertProgress(step: .finding)
        let running = identity.build
        return await recentBuilds(limit: 20)
            .filter { $0.switchable && KeptVersionStore.isNewer(running, than: $0.build) }
            .max { KeptVersionStore.isNewer($1.build, than: $0.build) }?.build
    }
}
