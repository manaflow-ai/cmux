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
    @concurrent static func warm(store: KeptVersionStore, build: String, log: UpdateLogBuffer) async {
        guard let kept = store.list(teams: false).first(where: { $0.build == build }) else { return }
        let started = ContinuousClock.now
        let schemas = await StoreSchemaProbe(bundle: kept.bundle).readable()
        log.append("kept \(build): first run of its code took \(ContinuousClock.now - started)")
        guard let schemas, kept.storeSchemas == nil else { return }
        // Beside the bundle, not in it: the seal is untouched (the run changes no file's ctime either).
        let file = kept.bundle.deletingLastPathComponent().appending(path: KeptVersionStore.recordName)
        guard var record = KeptRecord.read(from: file) else { return }
        record.storeSchemas = schemas
        do { try record.save(to: file) } catch { log.append("kept \(build): could not record its stores: \(error)") }
    }
}
