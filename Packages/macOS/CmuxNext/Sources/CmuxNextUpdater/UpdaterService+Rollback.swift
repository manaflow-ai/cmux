public import CmuxUpdater
public import Foundation
import CmuxNextWakeups

/// What a rollback compares, read off the main actor
/// (``UpdaterService/rollbackInputs(to:stateDirectories:)``).
nonisolated public struct RollbackInputs: Sendable {
    /// Kept versions, newest first. The rollback's target carries the schemas it reads (its
    /// Info.plist, its record, else its own CLI; nil when none says) and its checked team.
    public var kept: [KeptVersion]
    /// The newest schema each store holds; nil when they could not be read.
    public var stored: [String: Int]?
    /// The running app's signing team; nil for an unsigned app.
    public var teamID: String?

    public init(kept: [KeptVersion], stored: [String: Int]?, teamID: String? = nil) {
        self.kept = kept
        self.stored = stored
        self.teamID = teamID
    }
}

/// What a rollback's swap changed, so a refused quit can put it back
/// (``UpdaterService/undoRollbackSwap(_:)``).
struct RollbackSwapped {
    let target: KeptVersion
    /// The kept build's record, read before the swap removed its folder.
    var targetRecord: KeptRecord?
    /// The skip and picked build before the swap.
    let skip: String?
    let picked: String?
}

/// The keep's end or the quit's limit, whichever comes first (``UpdaterService/prepareForQuitAfterKeep(limit:)``).
@MainActor
final class KeepRace {
    var continuation: CheckedContinuation<Void, Never>?
    let timer = DemandTimer(owner: "UpdaterService.quitKeepLimit")
    func finish() {
        timer.cancel()
        continuation?.resume()
        continuation = nil
    }
}

/// A staged update waits that this app cannot cancel: a rollback would quit into it.
struct StagedUpdateWaits: Error, CustomStringConvertible {
    let build: String
    var description: String { "the staged update \(build) would install as cmux quits" }
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
        let bundleIdentifier = identity.bundleIdentifier ?? "cmux", keys = keptRecordKeys
        return KeptVersionStore(root: root, teamID: { UpdateDropBack.signingTeam(of: $0) },
                                quickTeamID: { UpdateDropBack.quickSigningTeam(of: $0) },
                                recordKey: { keys.key(bundleIdentifier: bundleIdentifier) })
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
        let partialRecord = runningRecord()
        let log = log
        let work = work
        // task-owner: one clone that ends by itself; the install waits for nothing it does. The clone and the
        // prune's signature reads run on the files lane, best effort (nobody waits), and quit waits for them.
        keepTask = Task(priority: WorkPriority.bestEffort.taskPriority) { [weak self] in
            // The stores this build reads, from its own CLI when its Info.plist does not say: asked
            // now, so going back to it never waits on that probe.
            let record = partialRecord
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
            // The kept copy's own CLI runs once now (KeptWarmup): macOS checks a new bundle's code on
            // its first launch (3.4 s for a NIGHTLY clone), so going back to it later does not; its
            // answer is the stores the copy reads when its Info.plist does not say.
            if kept { await KeptWarmup.warm(store: store, build: build, log: log, runningBuild: build) }
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
            // The install is waiting: the full check of the copy runs at the next launch (sealPending).
            try keptVersions.keep(bundle: Bundle.main.bundleURL, build: identity.build, limit: preferences.keepPreviousVersions,
                                  record: runningRecord(), check: .later)
            log.append("kept \(identity.build) for rollback before installing \(build)")
        } catch {
            log.append("could not keep \(identity.build) for rollback: \(error)")
        }
    }

    /// Reads what a rollback to `build` (nil: the previous build) compares, off the main actor.
    /// Only that build is checked: its team (sealed by the full check when it was kept, else every
    /// file now) and, when neither its Info.plist nor its record names its schemas and only once
    /// that check passed, its own CLI. Every other kept build's team is the record's, unchecked,
    /// and the decision never takes one of them. The stored schemas (one run of the running build's
    /// CLI per state root, `stateDirectories`; nil: cmux-tui's default) are read beside it, and the
    /// running app's team is its own code's (no file read).
    public func rollbackInputs(to build: String? = nil, stateDirectories: [URL?]) async -> RollbackInputs {
        let store = keptVersions
        let bundle = Bundle.main.bundleURL
        let work = work
        // task-owner: the rollback's read; awaited below.
        async let stored = StoreSchemaProbe(bundle: bundle).stored(stateDirectories: stateDirectories)
        var kept = (try? await work.run(.userVisible, mayBlock: .files) { store.list(teams: false) }) ?? []
        let running = UpdateDropBack.runningTeam
        let target = build ?? RollbackDecision.previous(kept: kept, running: identity.build)?.build
        if let index = kept.firstIndex(where: { $0.build == target }) {
            let picked = kept[index]
            kept[index].teamID = (try? await work.run(.userVisible, mayBlock: .files) { store.checkedTeam(of: picked) }) ?? nil
            // Its CLI runs only once its signature is this app's team: a kept bundle changed on disk never
            // runs code as the app (``RollbackDecision`` refuses it on the team before any schema).
            if kept[index].storeSchemas == nil, let running, kept[index].teamID == running {
                kept[index].storeSchemas = await StoreSchemaProbe(bundle: picked.bundle, timeout: .seconds(30)).readable()
            }
        }
        return RollbackInputs(kept: kept, stored: await stored, teamID: running)
    }

    /// Whether a rollback to `build` (nil: the previous build) would run.
    public func rollbackDecision(to build: String?, inputs: RollbackInputs) -> Result<KeptVersion, RollbackRefusal> {
        guard let stored = inputs.stored else { return .failure(.storesUnknown) }
        return RollbackDecision.decide(kept: inputs.kept, build: build, running: identity.build, stored: stored,
                                       teamID: inputs.teamID)
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
    func swapForRollback(to build: String?, inputs: RollbackInputs) async throws -> RollbackSwapped {
        let target = try rollbackDecision(to: build, inputs: inputs).get()
        UpdateDropBack.mark("revert.decided")
        // A staged update would install as the quit ends and relaunch forward (cmux#41013 review
        // F2): it is cancelled first, and a rollback does not run while one it cannot cancel waits.
        if let staged = stagedBuild(), !staged.isEmpty {
            guard cancelStaged() else { throw StagedUpdateWaits(build: staged) }
            log.append("rollback: cancelled the staged update \(staged), so the quit does not install it")
        }
        revert = RevertProgress(step: .swapping, target: target.build, label: RevertTarget(kept: target).label)
        let bundle = Bundle.main.bundleURL, current = identity.build, store = keptVersions
        let limit = preferences.keepPreviousVersions, record = runningRecord()
        let swapped = RollbackSwapped(target: target, skip: defaults.string(forKey: Self.skipsBuildsThroughKey),
                                      picked: defaults.string(forKey: Self.pickedBuildKey))
        let targetRecord = try await work.run(.userVisible, mayBlock: .files) { () -> KeptRecord? in
            let targetRecord = KeptRecord.read(from: target.bundle.deletingLastPathComponent().appending(path: KeptVersionStore.recordName))
            try RollbackSwap.perform(current: bundle, currentBuild: current, target: target, store: store, limit: limit, record: record)
            return targetRecord
        }
        UpdateDropBack.mark("revert.swapped")
        defaults.set(identity.build, forKey: Self.skipsBuildsThroughKey)
        defaults.set(target.build, forKey: Self.pickedBuildKey)
        controller?.skipsBuildsThrough = identity.build
        log.append("rolled back \(identity.build) -> \(target.build)")
        return RollbackSwapped(target: target, targetRecord: targetRecord, skip: swapped.skip, picked: swapped.picked)
    }

    /// The rollback's quit was refused (cmux#41013 review F3): the running build goes back in place,
    /// the kept build back to the store, and the skip and picked build back to what they were, so
    /// cmux runs on as before the click. False when the swap back failed (the next launch opens
    /// the kept build).
    func undoRollbackSwap(_ swapped: RollbackSwapped) async -> Bool {
        let bundle = Bundle.main.bundleURL, running = identity.build, store = keptVersions
        do {
            try await work.run(.userVisible, mayBlock: .files) {
                try RollbackSwap.undo(current: bundle, runningBuild: running, target: swapped.target,
                                      targetRecord: swapped.targetRecord, store: store)
            }
        } catch {
            log.append("rollback: the quit was refused, and \(running) could not be put back: \(error); \(swapped.target.build) opens on the next launch")
            return false
        }
        for (key, value) in [(Self.skipsBuildsThroughKey, swapped.skip), (Self.pickedBuildKey, swapped.picked)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        controller?.skipsBuildsThrough = swapped.skip
        log.append("rollback: the quit was refused; \(running) is back in place and \(swapped.target.build) kept")
        await refreshRevertOffer()
        return true
    }

    /// The quit is decided: the keep that started when an update staged
    /// (``keepRunningBuildForRollback()``) finishes first, up to `limit`, then ``prepareForQuit()``.
    /// A quit right after staging must not end the process mid-keep, or the build this Mac came
    /// from is lost to Go back (cmux#41013 review F4); the App arms its quit deadline after this.
    public func prepareForQuitAfterKeep(limit: Duration = .seconds(20)) async {
        if keptRunningBuild == .running, let keepTask {
            log.append("quit: waiting for the keep of \(identity.build) for rollback")
            let race = KeepRace()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                race.continuation = continuation
                // task-owner: the keep's end, or the limit's: the first resumes the quit, the other is a no-op.
                Task { await keepTask.value; race.finish() }
                race.timer.schedule(after: limit) { @MainActor in race.finish() }
            }
            if keptRunningBuild == .running { log.append("quit: the keep of \(identity.build) did not finish in \(limit); the next launch tidies it") }
        }
        prepareForQuit()
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
        let store = keptVersions, bundle = Bundle.main.bundleURL, log = log, work = work, running = identity.build
        // task-owner: a launch tidy that ends by itself; nobody waits on it.
        Task(priority: WorkPriority.bestEffort.taskPriority) { [weak self] in
            let tidied = (try? await work.run(.bestEffort, mayBlock: .files) {
                RollbackSwap.recover(current: bundle, store: store) + store.sweep() + store.sealPending(runningBuild: running).map { "sealed \($0)" }
            }) ?? []
            if !tidied.isEmpty { log.append("rollback: tidied what a cut-short keep or swap left: \(tidied.joined(separator: ", "))") }
            // A keep made at a click, or one whose first run a quit cut short, runs once now.
            await self?.refreshRevertOffer()
            await KeptWarmup.warmPending(store: store, log: log, runningBuild: running)
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
