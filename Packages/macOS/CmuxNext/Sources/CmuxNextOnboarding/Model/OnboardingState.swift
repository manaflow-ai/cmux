public import Foundation

/// Whether the user has finished or skipped onboarding, kept in one small
/// file per cmux channel on this Mac account (release, nightly, rc,
/// staging, each tagged dev build), so a dev build's Skip does not hide
/// onboarding in nightly. All access goes through `OnboardingStateQueue`.
public nonisolated struct OnboardingStateFile: Sendable {
    public static let environmentKey = "CMUX_NEXT_ONBOARDING_STATE"
    /// Bump to show onboarding again after a large change to it.
    public static let currentVersion = 1
    /// The release app's bundle id: the only channel that reads the file
    /// every channel shared before (`legacyURL`).
    public static let releaseBundleID = "com.cmuxterm.app"

    public let url: URL
    /// Read while `url` does not exist yet (release only): the first write
    /// moves that state to `url`, once.
    public let legacyURL: URL?

    public init(url: URL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL
    }

    /// `~/Library/Application Support/cmux/onboarding/<bundle id>.json`, or
    /// the path in `CMUX_NEXT_ONBOARDING_STATE` (test launches). Release
    /// starts from the old shared `cmux/onboarding.json`.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleID: String?,
        supportDirectory: URL? = nil
    ) -> OnboardingStateFile {
        if let path = environment[environmentKey], !path.isEmpty { return OnboardingStateFile(url: URL(fileURLWithPath: path)) }
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        let cmux = support.appending(path: "cmux")
        let scope = scopeName(bundleID)
        return OnboardingStateFile(
            url: cmux.appending(path: "onboarding").appending(path: "\(scope).json"),
            legacyURL: scope == releaseBundleID ? cmux.appending(path: "onboarding.json") : nil
        )
    }

    /// The file name of a channel: its bundle id; `unbundled` for a bare
    /// executable (never the release state).
    static func scopeName(_ bundleID: String?) -> String {
        let id = (bundleID ?? "").replacing(/[^A-Za-z0-9.\-]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return id.isEmpty ? "unbundled" : id
    }

    struct Record: Codable {
        var version: Int
        var completed: Bool
        var date: Date
        /// False while the first run is unfinished; nil in records written
        /// before resume existed, which were always an end.
        var finished: Bool?
        /// The step the first run is at (`Step` raw value); kept after it
        /// finished, for Continue Setup.
        var step: String?
        /// Later launches that still show an unfinished first run. Each
        /// launch that shows it uses one, however it ends (close, quit,
        /// crash); moving to a step gives the run its launches back.
        var launchesLeft: Int?

        /// Finished or skipped for the current version.
        var isFinished: Bool { version >= OnboardingStateFile.currentVersion && finished != false }
    }

    private func read() -> Record? {
        // concurrency-allow: nonisolated; callers read it on OnboardingStateQueue, off the main thread
        guard let data = (try? Data(contentsOf: url)) ?? legacyURL.flatMap({ try? Data(contentsOf: $0) }) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Replaces the file atomically and durably: a flushed temporary file
    /// renamed over it, so a crash leaves the old record or the new one.
    private func write(_ record: Record) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// True when onboarding for the current version was never finished or skipped.
    public func needsOnboarding() -> Bool {
        guard let record = read() else { return true }
        return !record.isFinished
    }

    /// What a launch does about onboarding.
    public enum LaunchShow: Equatable, Sendable {
        /// Never seen: the first run from its start.
        case start
        /// An unfinished first run at its step.
        case resume(OnboardingModel.Step)
        /// Nothing: finished, skipped, or its launches ran out.
        case none
    }

    /// How many later launches show the first run again after a launch
    /// that showed it, whether the person closed it or quit ("not now").
    public static let notNowLaunches = 2

    /// The launch decision. Counted at the show, not at the close: Cmd-Q
    /// closes no window, and a crash runs no code.
    public func takeLaunchShow(now: Date = Date()) -> LaunchShow {
        guard let record = read(), record.version >= Self.currentVersion else {
            try? write(Record(version: Self.currentVersion, completed: false, date: now, finished: false, launchesLeft: Self.notNowLaunches))
            return .start
        }
        guard !record.isFinished else { return .none }
        // A record written before launches were counted at the show.
        let left = record.launchesLeft ?? Self.notNowLaunches
        guard left > 0 else { return .none }
        var used = record
        used.launchesLeft = left - 1
        used.date = now
        try? write(used)
        return record.step.flatMap(OnboardingModel.Step.init(rawValue:)).map(LaunchShow.resume) ?? .start
    }

    /// Records the step the first run is at. Once finished it stays
    /// finished (Continue Setup only moves the saved step); an unfinished
    /// run the person moved in gets its launches back.
    public func markProgress(_ step: OnboardingModel.Step, interacted: Bool = true, now: Date = Date()) throws {
        let previous = read()
        if var finished = previous, finished.isFinished {
            guard finished.step != step.rawValue else { return }
            finished.step = step.rawValue
            return try write(finished)
        }
        let unfinished = previous.flatMap { $0.version >= Self.currentVersion ? $0 : nil }
        let left = interacted ? Self.notNowLaunches : unfinished?.launchesLeft ?? Self.notNowLaunches
        try write(Record(version: Self.currentVersion, completed: false, date: now, finished: false, step: step.rawValue, launchesLeft: left))
    }

    /// The step Continue Setup opens: where the first run was left, also
    /// after it finished; nil when none was saved.
    public func resumeStep() -> OnboardingModel.Step? {
        guard let record = read(), record.version >= Self.currentVersion else { return nil }
        return record.step.flatMap(OnboardingModel.Step.init(rawValue:))
    }

    /// Records that onboarding ended (`completed` false: skipped). A run
    /// once completed stays completed.
    public func markDone(completed: Bool, now: Date = Date()) throws {
        let previous = read()
        let wasCompleted = previous?.isFinished == true && previous?.completed == true
        try write(Record(version: Self.currentVersion, completed: completed || wasCompleted, date: now, finished: true, step: previous?.step))
    }
}
