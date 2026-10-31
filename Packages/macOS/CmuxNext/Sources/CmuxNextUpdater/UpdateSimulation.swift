import CmuxNextCompat
import Foundation

/// A pretend staged update for the Update Ready card (DEV and NIGHTLY; nothing downloads or
/// installs, ``UpdaterService/debugStage(version:notes:)``): `debug.updater {action: "stage"}`
/// with sample notes (``stageSample(_:version:changes:)``), and Debug Settings "Simulate pending
/// update" (`sidebar.updateCard.simulatePending`; Leo 2026-10-20: make the update card visibly
/// verifiable) or `debug.updater {action: "simulate"}` with real published notes
/// (``simulate()``): the newest published build's that has highlights, else this build's own,
/// else the sample notes when offline with nothing cached.
@MainActor
public final class UpdateSimulation {
    /// What a sample stage shows by default, and the pretend version of a simulation whose notes
    /// are not a newer build.
    public nonisolated static let sampleVersion = "1.99.0"

    private weak var updater: UpdaterService?
    private var observation: Task<Void, Never>?
    private var reading: Task<Void, Never>?

    public init(updater: UpdaterService) {
        self.updater = updater
    }

    /// `debug.updater {action: "stage", version?, changes?}`: stages `version` (default
    /// ``sampleVersion``) with `changes` sample notes (default 12). Returns both.
    @discardableResult
    public static func stageSample(_ updater: UpdaterService, version: String?, changes: Double?) -> (version: String, changes: Int) {
        let version = version ?? sampleVersion
        let count = max(0, Int(changes ?? 12))
        updater.debugStage(version: version, notes: .debugFake(version: version, changes: count))
        return (version, count)
    }

    /// Follows the Debug Settings switch `isOn` while the updater lives: on stages the pretend
    /// update, off follows the real updater again. An observation, not a poll; it keeps this
    /// simulation alive. A build without Debug Settings never turns it on.
    public func follow(_ isOn: @escaping @MainActor @Sendable () -> Bool) {
        observation?.cancel()
        observation = Task {
            var last = false
            for await on in ObservationStream(isOn) where on != last {
                last = on
                guard self.updater != nil else { return }
                if on {
                    self.simulate()
                } else {
                    self.end()
                }
            }
        }
    }

    /// Stages the pretend update once its notes are read. Returns whether published notes can be
    /// read at all (false: no notes store, so the sample notes show).
    @discardableResult
    public func simulate() -> Bool {
        reading?.cancel()
        guard let updater else { return false }
        let store = updater.changelogNotes ?? updater.releaseNotes
        let running = updater.identity.build
        // Held strongly until the notes are read: a one-shot simulation has no other owner.
        reading = Task {
            let notes = await Self.notes(store: store, runningBuild: running)
            guard !Task.isCancelled else { return }
            self.stage(with: notes)
        }
        return store != nil
    }

    /// Ends the simulation (and one still reading its notes): the real updater shows again.
    public func end() {
        reading?.cancel()
        reading = nil
        updater?.debugStage(version: nil, notes: nil)
    }

    /// Stages `notes` (nil: the sample notes) under a version that is not the running one, so the
    /// gate that never offers the running build (`UpdaterService.offersStagedUpdate`) still shows
    /// the card. Returns the version staged (nil once the updater is gone).
    @discardableResult
    func stage(with notes: ReleaseNotes?) -> String? {
        guard let updater else { return nil }
        let version = Self.version(notes: notes, running: updater.identity)
        updater.debugStage(version: version, notes: notes ?? .debugFake(version: version, changes: 12))
        return version
    }

    /// The newest published notes with highlights, else the running build's own; nil offline
    /// with nothing cached.
    static func notes(store: ReleaseNotesStore?, runningBuild: String) async -> ReleaseNotes? {
        guard let store else { return nil }
        if let build = build(from: await store.index()), let notes = await store.notes(for: build) { return notes }
        return runningBuild.isEmpty ? nil : await store.notes(for: runningBuild)
    }

    /// The build whose notes the simulation shows: the newest published build with highlights,
    /// else the newest one at all; nil for an empty index (offline with nothing cached). Builds of
    /// one day order by number ("100" is newer than "99").
    nonisolated static func build(from index: [ReleaseNotesIndexEntry]) -> String? {
        let newest = index.sorted { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.build.compare(rhs.build, options: .numeric) == .orderedDescending
        }
        return (newest.first { $0.highlights > 0 } ?? newest.first)?.build
    }

    /// The version a simulation stages: the notes' own when they are a build newer than the
    /// running one, else the clearly pretend ``sampleVersion``. Never the running version: on
    /// the newest nightly the newest notes are its own, and the gate hides that version.
    nonisolated static func version(notes: ReleaseNotes?, running: UpdateBuildIdentity) -> String {
        if let notes, !notes.shortVersion.isEmpty, notes.shortVersion != running.shortVersion,
           notes.build.compare(running.build, options: .numeric) == .orderedDescending {
            return notes.shortVersion
        }
        return running.shortVersion == sampleVersion ? "\(sampleVersion).1" : sampleVersion
    }
}
