import Foundation

/// Runs a kept build's own CLI once, right after it is kept, off the click.
///
/// macOS checks a bundle's code the first time it runs (the notarization and Gatekeeper
/// assessment): a NIGHTLY copied by APFS clone took 3.4 s from exec to its first line of cmux code
/// at its first launch and 0.4 s at the next (capture Mac, 2026-11-11). Going back to a kept build
/// is that first launch, with the windows already gone. Running the copy's bundled `cmux` once at
/// keep time makes macOS check it then, and the check holds when the swap moves the bundle into
/// place (the app opened 1.1 s after exec instead of 3.5 s). The run is `cmux __store-schemas`: its
/// answer is the stores the copy reads, kept in its record when its Info.plist does not say.
nonisolated enum KeptWarmup {
    /// `@concurrent`: the list and the record are file I/O, off the caller's actor.
    /// A build whose code does not run (its team does not check, or its CLI fails) is recorded as
    /// failed by `runningBuild`, and ``warmPending(store:log:runningBuild:running:)`` does not try it
    /// again until another build runs.
    @concurrent static func warm(store: KeptVersionStore, build: String, log: UpdateLogBuffer, runningBuild: String,
                                 running: String? = UpdateDropBack.runningTeam) async {
        guard let kept = store.list(teams: false).first(where: { $0.build == build }) else { return }
        // Its code runs only once its signature is this app's team (the seal makes that quick): a
        // kept bundle changed on disk never runs code as the app.
        guard let running, store.checkedTeam(of: kept) == running else {
            log.append("kept \(build): not run, its signature is not this app's")
            return failed(kept, by: runningBuild, log: log)
        }
        let started = ContinuousClock.now
        let schemas = await StoreSchemaProbe(bundle: kept.bundle).readable()
        log.append("kept \(build): first run of its code took \(ContinuousClock.now - started)")
        // An answer means its code ran. Recorded beside the bundle, not in it: the seal is untouched
        // (the run changes no file's ctime either).
        guard let schemas else { return failed(kept, by: runningBuild, log: log) }
        let file = kept.bundle.deletingLastPathComponent().appending(path: KeptVersionStore.recordName)
        guard var record = KeptRecord.read(from: file) else { return }
        record.warmed = true
        record.warmFailedBy = nil
        // The schemas go in signed, and only into a record the key vouched for before: one another
        // process wrote stays unsigned, so its schemas never count (the click runs the CLI again).
        let key = store.recordKey()
        if record.storeSchemas == nil, kept.storeSchemas == nil, record.isAuthentic(key: key) {
            record.storeSchemas = schemas
            record.sign(key: key)
        }
        do { try record.save(to: file) } catch { log.append("kept \(build): could not record its first run: \(error)") }
    }

    /// Runs each kept build whose code has not run since it was kept: a keep made at a click, or
    /// one whose run a quit cut short (Restart to Update right after the update staged). At launch.
    @concurrent static func warmPending(store: KeptVersionStore, log: UpdateLogBuffer, runningBuild: String,
                                        running: String? = UpdateDropBack.runningTeam) async {
        let pending = store.list(teams: false).filter { kept in
            let record = KeptRecord.read(from: kept.bundle.deletingLastPathComponent().appending(path: KeptVersionStore.recordName))
            return record?.warmed != true && record?.warmFailedBy != runningBuild
        }
        for kept in pending { await warm(store: store, build: kept.build, log: log, runningBuild: runningBuild, running: running) }
    }

    private static func failed(_ kept: KeptVersion, by runningBuild: String, log: UpdateLogBuffer) {
        let file = kept.bundle.deletingLastPathComponent().appending(path: KeptVersionStore.recordName)
        var record = KeptRecord.read(from: file) ?? KeptRecord(build: kept.build)
        record.warmFailedBy = runningBuild
        do { try record.save(to: file) } catch { log.append("kept \(kept.build): could not record its failed run: \(error)") }
    }
}
