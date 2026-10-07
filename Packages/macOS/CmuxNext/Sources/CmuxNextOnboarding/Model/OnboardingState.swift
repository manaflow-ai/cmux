public import Foundation

/// Whether the user has finished or skipped onboarding, kept in one small
/// file shared by every cmux build on this Mac account (release, nightly,
/// tagged dev builds), so it shows once, not once per build.
public nonisolated struct OnboardingStateFile: Sendable {
    public static let environmentKey = "CMUX_NEXT_ONBOARDING_STATE"
    /// Bump to show onboarding again after a large change to it.
    public static let currentVersion = 1

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/cmux/onboarding.json`, or the path in
    /// `CMUX_NEXT_ONBOARDING_STATE` (test launches).
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> OnboardingStateFile {
        if let path = environment[environmentKey], !path.isEmpty { return OnboardingStateFile(url: URL(fileURLWithPath: path)) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return OnboardingStateFile(url: support.appending(path: "cmux/onboarding.json"))
    }

    struct Record: Codable {
        var version: Int
        var completed: Bool
        var date: Date
        /// False while the first run is unfinished; nil in records written
        /// before resume existed, which were always an end.
        var finished: Bool?
        /// The step an unfinished first run is at (`Step` raw value).
        var step: String?
        /// False after the person closed it ("not now") until they move to a
        /// step again; nil or true: it was in use (a quit or crash resumes it).
        var active: Bool?
        /// Launches left that show it again after "not now".
        var launchesLeft: Int?
    }

    private func read() -> Record? {
        // concurrency-allow: nonisolated; callers read it off the main thread
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func write(_ record: Record) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    /// True when onboarding for the current version was never finished or skipped.
    public func needsOnboarding() -> Bool {
        guard let record = read() else { return true }
        return record.version < Self.currentVersion || record.finished == false
    }

    /// What a launch does about onboarding.
    public enum LaunchShow: Equatable, Sendable {
        /// Never seen: the first run from its start.
        case start
        /// An unfinished first run at its step.
        case resume(OnboardingModel.Step)
        /// Nothing: finished, skipped, or "not now" ran out.
        case none
    }

    /// How many later launches show the first run again after the person
    /// closed it ("not now").
    public static let notNowLaunches = 2

    /// The person closed the first run without Skip or Done ("not now").
    public func markNotNow(now: Date = Date()) throws {
        guard var record = read(), record.finished == false else { return }
        record.active = false
        record.launchesLeft = Self.notNowLaunches
        record.date = now
        try write(record)
    }

    /// The launch decision; a "not now" show uses up one of its launches.
    public func takeLaunchShow(now: Date = Date()) -> LaunchShow {
        guard let record = read() else { return .start }
        guard needsOnboarding() else { return .none }
        let step = record.step.flatMap(OnboardingModel.Step.init(rawValue:))
        let show = step.map(LaunchShow.resume) ?? .start
        guard record.active == false else { return show }
        let left = record.launchesLeft ?? 0
        guard left > 0 else { return .none }
        var used = record
        used.launchesLeft = left - 1
        used.date = now
        try? write(used)
        return show
    }

    /// Records that the first run is unfinished and at `step`.
    public func markProgress(_ step: OnboardingModel.Step, interacted: Bool = true, now: Date = Date()) throws {
        var record = Record(version: Self.currentVersion, completed: false, date: now, finished: false, step: step.rawValue)
        if !interacted, let previous = read(), previous.finished == false {
            // Only showing a step keeps a pending "not now" and its launches.
            record.active = previous.active
            record.launchesLeft = previous.launchesLeft
        }
        try write(record)
    }

    /// The step an unfinished first run was left at, or nil.
    public func resumeStep() -> OnboardingModel.Step? {
        guard let record = read(), record.version >= Self.currentVersion, record.finished == false else { return nil }
        return record.step.flatMap(OnboardingModel.Step.init(rawValue:))
    }

    /// Records that onboarding ended (`completed` false: skipped).
    public func markDone(completed: Bool, now: Date = Date()) throws {
        try write(Record(version: Self.currentVersion, completed: completed, date: now, finished: true))
    }
}
