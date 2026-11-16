public import CmuxUpdater
public import Foundation
import CmuxNextWakeups

/// What a rollback compares, read off the main actor
/// (``UpdaterService/rollbackInputs(to:checkOnly:stateDirectories:)``).
nonisolated public struct RollbackInputs: Sendable {
    /// Kept versions, newest first. The rollback's target carries the schemas it reads (its
    /// Info.plist, its recorded probe, else its own CLI; nil when none says) and its team.
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
        return KeptVersionStore(root: root, teamID: { UpdateDropBack.signingTeam(of: $0) }, teams: signingTeams)
    }

    /// An update staged: keep the running bundle for rollback now, off the
    /// main thread, so the click that installs does no disk work (the
    /// clone, and the prune's signature reads of every kept build, take
    /// seconds on a busy disk). Once per running build.
    func keepRunningBuildForRollback() {
        guard keptRunningBuild == nil else { return }
        keptRunningBuild = .running
        let store = keptVersions, bundle = Bundle.main.bundleURL, build = identity.build, limit = preferences.keepPreviousVersions
        let log = log
        let work = work
        // task-owner: one clone that ends by itself; the install waits for nothing it does. The clone and the
        // prune's signature reads run on the files lane, best effort (nobody waits), and quit waits for them.
        keepTask = Task(priority: WorkPriority.bestEffort.taskPriority) { [weak self] in
            let kept = (try? await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { () -> Bool in
                #if DEBUG || CMUX_BENCH_HOOKS
                UpdateHarness.mark("keep_previous_start")
                #endif
                defer {
                    #if DEBUG || CMUX_BENCH_HOOKS
                    UpdateHarness.mark("keep_previous_end")
                    #endif
                }
                do {
                    try store.keep(bundle: bundle, build: build, limit: limit)
                    log.append("kept \(build) for rollback when the update staged")
                    return true
                } catch {
                    log.append("could not keep \(build) for rollback: \(error)")
                    return false
                }
            }) ?? false
            // The clone just kept is this build (the running path may hold another one by now, after a
            // switch); a rollback to it later reads this answer instead of starting a cold copy.
            let clone = store.root.appending(path: build, directoryHint: .isDirectory).appending(path: bundle.lastPathComponent)
            if kept, let schemas = await StoreSchemaProbe(bundle: clone).readable() {
                _ = try? await work.run(.bestEffort, mayBlock: .files) { store.recordSchemas(schemas, for: build) }
            }
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
            try keptVersions.keep(bundle: Bundle.main.bundleURL, build: identity.build, limit: preferences.keepPreviousVersions)
            log.append("kept \(identity.build) for rollback before installing \(build)")
        } catch {
            log.append("could not keep \(identity.build) for rollback: \(error)")
        }
    }

    /// Reads what a rollback to `build` (nil: the newest kept) compares, off the main actor. Only
    /// that build is checked: its signature (one full check of every nested binary), then, without
    /// recorded schemas and only when that check passed, its own CLI; the stored schemas and the
    /// running app's team are read beside it. `stateDirectories` are the
    /// daemons' state roots (nil: cmux-tui's default). `checkOnly` (the card's "would it run")
    /// takes an earlier signature answer for the target; a rollback that runs checks it afresh.
    public func rollbackInputs(to build: String?, checkOnly: Bool = false, stateDirectories: [URL?]) async -> RollbackInputs {
        let store = keptVersions
        let bundle = Bundle.main.bundleURL
        let work = work
        // A directory listing and a read of each kept bundle's Info.plist: file I/O on the files lane. The
        // probes are awaited child processes (no thread waits).
        var kept = (try? await work.run(.userVisible, mayBlock: .files) { store.list() }) ?? []
        async let stored = StoreSchemaProbe(bundle: bundle).stored(stateDirectories: stateDirectories)
        async let team = try? work.run(.userVisible, mayBlock: .files) {
            store.teams.team(of: bundle, read: UpdateDropBack.signingTeam(of:))
        }
        let index = build == nil ? kept.indices.first : kept.firstIndex { $0.build == build }
        let running = await team ?? nil
        if let index {
            let target = kept[index]
            // A check may reuse an earlier answer only when no code of the bundle runs after it: without a
            // valid record its CLI runs next, so it is checked afresh (a CLI replaced under an unchanged
            // seal keeps the cache key).
            let reuses = checkOnly && target.storeSchemas != nil
            kept[index] = (try? await work.run(.userVisible, mayBlock: .files) { store.verified(target, reusing: reuses) }) ?? target
            // Its CLI runs only once its signature is this app's team: a kept bundle changed on disk never
            // runs code as the app (``RollbackDecision`` refuses it on the team before any schema).
            if kept[index].storeSchemas == nil, let running, kept[index].teamID == running,
               let probed = await StoreSchemaProbe(bundle: target.bundle, timeout: .seconds(30)).readable() {
                kept[index].storeSchemas = probed
                _ = try? await work.run(.bestEffort, mayBlock: .files) { store.recordSchemas(probed, for: target.build) }
            }
        }
        return RollbackInputs(kept: kept, stored: await stored, teamID: running)
    }

    /// Whether a rollback to `build` (nil: the newest kept) would run.
    public func rollbackDecision(to build: String?, inputs: RollbackInputs) -> Result<KeptVersion, RollbackRefusal> {
        guard let stored = inputs.stored else { return .failure(.storesUnknown) }
        return RollbackDecision.decide(kept: inputs.kept, build: build, stored: stored, teamID: inputs.teamID)
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

    /// Rolls back to `build` (nil: the newest kept) when ``rollbackDecision``
    /// allows it: swaps the bundles (on the files lane: the clone of the running build and the
    /// renames are disk work), stops offering the build left behind, then quits keeping every
    /// session and lets `relaunch` reopen the app.
    @discardableResult
    public func rollback(to build: String?, inputs: RollbackInputs, relaunch: (URL) -> Void) async throws -> KeptVersion {
        let target = try rollbackDecision(to: build, inputs: inputs).get()
        let bundle = Bundle.main.bundleURL, current = identity.build, store = keptVersions, limit = preferences.keepPreviousVersions
        let started = ContinuousClock.now
        _ = try await work.run(.userBlocking, mayBlock: .files, shutdown: .blockShutdown) {
            try RollbackSwap.perform(current: bundle, currentBuild: current, target: target, store: store, limit: limit)
        }
        defaults.set(current, forKey: Self.skipsBuildsThroughKey)
        defaults.set(target.build, forKey: Self.pickedBuildKey)
        controller?.skipsBuildsThrough = current
        log.append("rolled back \(current) -> \(target.build) (swap \(started.duration(to: .now)))")
        willRelaunch?()
        relaunch(bundle)
        return target
    }

    /// Restores the skip after a rollback at launch, and asks before installing while the build the
    /// person picked runs; once another build runs (they installed forward), updates install as set.
    func restoreRollbackSkip() {
        controller?.skipsBuildsThrough = defaults.string(forKey: Self.skipsBuildsThroughKey)
        let picked = defaults.string(forKey: Self.pickedBuildKey)
        if picked != nil && picked != identity.build { defaults.removeObject(forKey: Self.pickedBuildKey) }
        controller?.asksBeforeInstalling = picked == identity.build
    }
}
