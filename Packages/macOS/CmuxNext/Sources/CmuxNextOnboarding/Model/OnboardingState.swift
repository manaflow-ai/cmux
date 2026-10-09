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

    /// The file's one record. Version 1 throughout: fields added later are
    /// optional, so a record written by an older build still decodes and a
    /// finished user stays finished.
    public struct Record: Codable, Sendable, Equatable {
        public var version: Int
        public var completed: Bool
        public var date: Date
        /// False while the first run is unfinished; nil in records written
        /// before resume existed, which were always an end.
        public var finished: Bool?
        /// The step the first run is at (`Step` raw value); kept after it
        /// finished, for Continue Setup.
        public var step: String?
        /// Later launches that still show an unfinished first run. Each
        /// launch that shows it uses one, however it ends (close, quit,
        /// crash); moving to a step gives the run its launches back.
        public var launchesLeft: Int?
        /// Why onboarding ended without the person ending it
        /// (`EndReason` raw value); nil when they did, or it has not ended.
        public var reason: String?
        /// What the first-run page saw (plans/cmux-next/onboarding.md 2).
        public var firstRun: FirstRun?

        public init(version: Int, completed: Bool, date: Date, finished: Bool? = nil, step: String? = nil,
                    launchesLeft: Int? = nil, reason: String? = nil, firstRun: FirstRun? = nil) {
            self.version = version
            self.completed = completed
            self.date = date
            self.finished = finished
            self.step = step
            self.launchesLeft = launchesLeft
            self.reason = reason
            self.firstRun = firstRun
        }

        /// Finished or skipped for the current version.
        public var isFinished: Bool { version >= OnboardingStateFile.currentVersion && finished != false }
    }

    /// Why onboarding ended by itself.
    public enum EndReason: String, Sendable {
        /// The launch found data of the user's own (`FirstRunGate`).
        case existingData = "existing-data"
    }

    /// The first-run page's local record: kept on this Mac only, never sent.
    public struct FirstRun: Codable, Sendable, Equatable {
        /// The furthest stage the page reached.
        public enum Stage: String, Codable, Sendable {
            case shown, projectPicked, signInShown, signInDone, promptSent
        }

        /// The first action that ended the first run.
        public enum Action: String, Codable, Sendable {
            case prompt, shell, url, dismiss
        }

        public var stage: Stage?
        public var action: Action?
        /// Time to first prompt: first main window visible to the first
        /// prompt acpmux accepted.
        public var firstPromptMilliseconds: Int?
        /// Whether "Make it yours" was opened from the page.
        public var openedMakeItYours: Bool?

        public init() {}

        enum CodingKeys: String, CodingKey { case stage, action, firstPromptMilliseconds, openedMakeItYours }

        /// A stage or action from a later build reads as nil instead of
        /// failing the whole record (which would reset onboarding).
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            stage = (try? container.decodeIfPresent(String.self, forKey: .stage)).flatMap { $0.flatMap(Stage.init(rawValue:)) }
            action = (try? container.decodeIfPresent(String.self, forKey: .action)).flatMap { $0.flatMap(Action.init(rawValue:)) }
            firstPromptMilliseconds = try? container.decodeIfPresent(Int.self, forKey: .firstPromptMilliseconds)
            openedMakeItYours = try? container.decodeIfPresent(Bool.self, forKey: .openedMakeItYours)
        }
    }

    /// The current record, nil when none was written (or it does not decode).
    public func record() -> Record? { read() }

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
        try write(Record(version: Self.currentVersion, completed: false, date: now, finished: false, step: step.rawValue, launchesLeft: left,
                         firstRun: unfinished?.firstRun))
    }

    /// The step Continue Setup opens: where the first run was left, also
    /// after it finished; nil when none was saved.
    public func resumeStep() -> OnboardingModel.Step? {
        guard let record = read(), record.version >= Self.currentVersion else { return nil }
        return record.step.flatMap(OnboardingModel.Step.init(rawValue:))
    }

    /// Records that onboarding ended (`completed` false: skipped; `reason`:
    /// it ended by itself). A run once completed stays completed.
    public func markDone(completed: Bool, reason: EndReason? = nil, now: Date = Date()) throws {
        let previous = read()
        let wasCompleted = previous?.isFinished == true && previous?.completed == true
        try write(Record(version: Self.currentVersion, completed: completed || wasCompleted, date: now, finished: true, step: previous?.step,
                         reason: reason?.rawValue, firstRun: previous?.firstRun))
    }
}
