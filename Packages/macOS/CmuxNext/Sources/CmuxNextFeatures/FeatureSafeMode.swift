import Atomics
import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation
import os

/// Which remote document a launch may apply, from the crash and fetch-failure
/// streaks: Chrome's variations safe mode
/// (components/variations/service/safe_seed_manager.cc, `SafeSeedManager`).
///
/// - A launch after a run that ended without a clean exit adds one to the
///   crash streak (`LaunchRecovery.countsTowardCrashStreak` in the App). A
///   clean run does not clear it: only a successful fetch does, so a document
///   that mostly crashes still ends in safe mode.
/// - Each fetch of the flags document adds one to the fetch-failure streak
///   when it starts; its success clears both streaks.
/// - At a crash streak of 3 or a fetch-failure streak of 25 the launch applies
///   the last known good document; at 4 or 50, no remote document. Sticky
///   kill switches stay off at both levels.
/// - The document a regular launch applied becomes the last known good one at
///   the first successful fetch of that run.
///
/// The streaks live in `<directory>/safe-mode.json` (Chrome keeps them in
/// local state). Every read and write of it runs, in order, on one
/// ``WorkSequence`` of ``BackgroundWork``'s files lane, never on the caller's
/// thread.
public nonisolated final class FeatureSafeMode: Sendable {
    /// `kCrashStreakSafeSeedThreshold`.
    public static let crashStreakLastKnownGoodThreshold = 3
    /// `kCrashStreakNullSeedThreshold`.
    public static let crashStreakNoRemoteThreshold = 4
    /// `kFetchFailureStreakSafeSeedThreshold`.
    public static let fetchFailureStreakLastKnownGoodThreshold = 25
    /// `kFetchFailureStreakNullSeedThreshold`.
    public static let fetchFailureStreakNoRemoteThreshold = 50

    /// `CMUX_FEATURES_SAFE_MODE=off` turns safe mode off for a lab run. Read
    /// only in bench builds (``honorsOverride``).
    public static let overrideVariable = "CMUX_FEATURES_SAFE_MODE"

    /// Whether this build reads ``overrideVariable``: bench builds only, so a
    /// shipped app always applies safe mode (`check-no-bench-hooks.sh`).
    #if CMUX_BENCH_HOOKS
    public static let honorsOverride = true
    #else
    public static let honorsOverride = false
    #endif

    /// The counts kept between launches.
    public struct Streaks: Codable, Sendable, Equatable {
        /// Launches in a row that followed a run without a clean exit, since the last successful fetch.
        public var crashes: Int
        /// Fetches started since the last successful one.
        public var fetchFailures: Int

        public static let zero = Streaks(crashes: 0, fetchFailures: 0)

        private enum CodingKeys: String, CodingKey {
            case crashes, fetchFailures
        }

        public init(crashes: Int, fetchFailures: Int) {
            self.crashes = max(0, crashes)
            self.fetchFailures = max(0, fetchFailures)
        }

        /// An edited or partly written file reads as no streak, as a missing
        /// Chrome pref reads as 0.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(crashes: try container.decodeIfPresent(Int.self, forKey: .crashes) ?? 0,
                      fetchFailures: try container.decodeIfPresent(Int.self, forKey: .fetchFailures) ?? 0)
        }

        mutating func addCrash() { crashes = crashes == .max ? .max : crashes + 1 }
        mutating func addFetchFailure() { fetchFailures = fetchFailures == .max ? .max : fetchFailures + 1 }
    }

    /// Which remote document a launch applies (`SafeSeedManager::GetSeedType`).
    public enum Level: String, Sendable, CaseIterable {
        /// The last document stored (`kRegularSeed`).
        case regular
        /// The last known good document, and the sticky kills of the last one (`kSafeSeed`).
        case lastKnownGood = "last-known-good"
        /// No document, only the sticky kills of both copies (`kNullSeed`).
        case noRemote = "no-remote"

        public init(_ streaks: Streaks) {
            if streaks.crashes >= FeatureSafeMode.crashStreakNoRemoteThreshold
                || streaks.fetchFailures >= FeatureSafeMode.fetchFailureStreakNoRemoteThreshold {
                self = .noRemote
            } else if streaks.crashes >= FeatureSafeMode.crashStreakLastKnownGoodThreshold
                || streaks.fetchFailures >= FeatureSafeMode.fetchFailureStreakLastKnownGoodThreshold {
                self = .lastKnownGood
            } else {
                self = .regular
            }
        }
    }

    /// This launch's safe mode, as the Labs page, `cmux settings
    /// feature-flags` and lab results show it.
    public struct State: Sendable, Equatable, CustomStringConvertible {
        /// The level this launch applies.
        public let level: Level
        /// The streaks at launch, this launch's crash count included.
        public let streaks: Streaks
        /// A bench run turned safe mode off (``FeatureSafeMode/overrideVariable``); ``level`` is then regular.
        public let overridden: Bool

        public init(streaks: Streaks, overridden: Bool = false) {
            self.streaks = streaks
            self.overridden = overridden
            level = overridden ? .regular : Level(streaks)
        }

        /// Whether the launch applies anything but the last document.
        public var isActive: Bool { level != .regular }

        /// `safe-mode=last-known-good crash-streak=3 fetch-failure-streak=0`.
        public var description: String {
            "safe-mode=\(overridden ? "overridden" : level.rawValue) crash-streak=\(streaks.crashes) fetch-failure-streak=\(streaks.fetchFailures)"
        }
    }

    /// Why the streak file was not read or written.
    public enum FileError: Error, Sendable, Equatable, CustomStringConvertible {
        /// The file exists and could not be read or decoded; the streaks read as zero.
        case unreadable(String)
        /// The file system refused the write.
        case notWritten(String)
        /// Shutdown dropped the item or the caller was cancelled before it ran.
        case notRun

        public var description: String {
            switch self {
            case .unreadable(let reason): "safe-mode streaks unreadable: \(reason)"
            case .notWritten(let reason): "safe-mode streaks not written: \(reason)"
            case .notRun: "safe-mode streaks not read or written: not run"
            }
        }
    }

    public let state: State
    /// `<directory>/safe-mode.json`.
    public let file: URL
    private let writes: WorkSequence
    private let report: @Sendable (String) -> Void
    /// True until the first successful fetch of a regular launch promotes its document.
    private let promotionPending: ManagedAtomic<Bool>

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "features")

    /// Reads the streaks, adds this launch's crash when the previous run ended
    /// without a clean exit, writes them back, and decides the level. Run it
    /// once per launch, before the composition root resolves the features.
    ///
    /// - Parameters:
    ///   - directory: the features folder in Application Support (the one `FeatureRemoteStore` uses).
    ///   - previousRunEndedUncleanly: `LaunchRecovery.countsTowardCrashStreak(previous:)`.
    ///   - environment: the launch environment; ``overrideVariable`` is read in bench builds only.
    ///   - work: the app's ``BackgroundWork``; the streak file is read and written on its files lane.
    ///   - report: gets each file failure and an active safe mode as a line, after the unified log
    ///     (subsystem `com.cmuxterm.app.next`, category `features`) has it; tests read it.
    public static func launch(
        directory: URL,
        previousRunEndedUncleanly: Bool,
        environment: [String: String],
        work: BackgroundWork,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> FeatureSafeMode {
        let file = directory.appending(path: "safe-mode.json", directoryHint: .notDirectory)
        let writes = work.sequence("features.safe-mode")
        let read: (streaks: Streaks, failures: [FileError])
        do {
            read = try await writes.run(.userVisible, shutdown: .blockShutdown) {
                var failures: [FileError] = []
                var streaks = Self.readOnLane(file, failures: &failures)
                if previousRunEndedUncleanly {
                    streaks.addCrash()
                    if let failure = Self.writeOnLane(streaks, to: file) { failures.append(failure) }
                }
                return (streaks: streaks, failures: failures)
            }
        } catch {
            read = (streaks: .zero, failures: [.notRun])
        }
        let overridden = honorsOverride && environment[overrideVariable] == "off"
        let safeMode = FeatureSafeMode(state: State(streaks: read.streaks, overridden: overridden), file: file,
                                       writes: writes, report: report)
        for failure in read.failures { safeMode.log("\(failure)", error: true) }
        if safeMode.state.isActive || overridden { safeMode.log("features \(safeMode.state)", error: safeMode.state.isActive) }
        return safeMode
    }

    private init(state: State, file: URL, writes: WorkSequence, report: @escaping @Sendable (String) -> Void) {
        self.state = state
        self.file = file
        self.writes = writes
        self.report = report
        promotionPending = ManagedAtomic(state.level == .regular)
    }

    /// The remote values this launch applies (resolution step 4,
    /// ``FeatureOverrides/remote``), by ``state``'s level.
    ///
    /// - Parameters:
    ///   - latest: what the last stored document gives this build.
    ///   - lastKnownGood: what the last known good document gives this build.
    ///   - registry: the registry whose `sticky` flags say which offs survive safe mode.
    public func remoteValues(latest: [String: Bool], lastKnownGood: [String: Bool], registry: FeatureRegistry) -> [String: Bool] {
        switch state.level {
        case .regular:
            return latest
        case .lastKnownGood:
            return lastKnownGood.merging(Self.stickyKills(in: latest, registry: registry)) { _, kill in kill }
        case .noRemote:
            return Self.stickyKills(in: lastKnownGood, registry: registry)
                .merging(Self.stickyKills(in: latest, registry: registry)) { _, kill in kill }
        }
    }

    /// The remote param values this launch applies (``FeatureParamList``'s
    /// `remote`), by ``state``'s level: the last document's, the last known
    /// good one's, or none. A param is no kill switch, so none survives `noRemote`.
    public func remoteParams(
        latest: [String: [String: String]],
        lastKnownGood: [String: [String: String]]
    ) -> [String: [String: String]] {
        switch state.level {
        case .regular: latest
        case .lastKnownGood: lastKnownGood
        case .noRemote: [:]
        }
    }

    /// A fetch of the flags document is starting: counts it as failed until
    /// ``recordFetchSucceeded(promotingActiveDocument:)`` (Chrome's
    /// `RecordFetchStarted`, which assumes the fetch fails).
    public func recordFetchStarted() async {
        await update { $0.addFetchFailure() }
    }

    /// A fetch of the flags document succeeded (a new document or not
    /// modified): at the first success of a regular launch,
    /// `promoteActiveDocument` stores the document this launch applied as the
    /// last known good one; then both streaks clear (Chrome's
    /// `RecordSuccessfulFetch`).
    public func recordFetchSucceeded(promotingActiveDocument promoteActiveDocument: @Sendable () async -> Void) async {
        if promotionPending.exchange(false, ordering: .acquiringAndReleasing) {
            await promoteActiveDocument()
        }
        await update { $0 = .zero }
    }

    /// The streaks as the file holds them now, read in order after every write submitted before.
    public func currentStreaks() async throws(FileError) -> Streaks {
        let file = file
        let read: (streaks: Streaks, failures: [FileError])
        do {
            read = try await writes.run(.userVisible) {
                var failures: [FileError] = []
                return (streaks: Self.readOnLane(file, failures: &failures), failures: failures)
            }
        } catch {
            throw .notRun
        }
        if let failure = read.failures.first { throw failure }
        return read.streaks
    }

    // MARK: Lane work (the safe-mode sequence on the files lane only)

    /// Reads, changes and writes the streaks in one item, so updates never interleave.
    private func update(_ change: @escaping @Sendable (inout Streaks) -> Void) async {
        let file = file
        let failures: [FileError]
        do {
            failures = try await writes.run(.bestEffort, shutdown: .blockShutdown) {
                var failures: [FileError] = []
                var streaks = Self.readOnLane(file, failures: &failures)
                change(&streaks)
                if let failure = Self.writeOnLane(streaks, to: file) { failures.append(failure) }
                return failures
            }
        } catch {
            failures = [.notRun]
        }
        for failure in failures { log("\(failure)", error: true) }
    }

    private static func readOnLane(_ file: URL, failures: inout [FileError]) -> Streaks {
        let data: Data
        do {
            data = try Data(blockingContentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return .zero
        } catch {
            failures.append(.unreadable(String(describing: error)))
            return .zero
        }
        do {
            return try JSONDecoder().blockingDecode(Streaks.self, from: data)
        } catch {
            failures.append(.unreadable(String(describing: error)))
            return .zero
        }
    }

    private static func writeOnLane(_ streaks: Streaks, to file: URL) -> FileError? {
        do {
            try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(streaks).blockingWrite(to: file, options: .atomic)
            return nil
        } catch {
            return .notWritten(String(describing: error))
        }
    }

    // MARK: Helpers

    /// The offs of sticky features in `values`.
    private static func stickyKills(in values: [String: Bool], registry: FeatureRegistry) -> [String: Bool] {
        values.filter { name, isEnabled in !isEnabled && registry.feature(named: name)?.sticky == true }
    }

    private func log(_ line: String, error: Bool) {
        if error {
            Self.logger.error("\(line, privacy: .public)")
        } else {
            Self.logger.notice("\(line, privacy: .public)")
        }
        report(line)
    }
}
