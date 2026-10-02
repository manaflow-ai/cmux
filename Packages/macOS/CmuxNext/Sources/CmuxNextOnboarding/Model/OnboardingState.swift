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
        /// The role step's answer (absent in files from before the step).
        var profile: OnboardingProfile?
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
        return record.version < Self.currentVersion
    }

    /// Records that onboarding ended (`completed` false: skipped), with
    /// `profile` or else the profile already saved.
    public func markDone(completed: Bool, profile: OnboardingProfile? = nil, now: Date = Date()) throws {
        try write(Record(version: Self.currentVersion, completed: completed, date: now, profile: profile ?? read()?.profile))
    }

    /// The role step's saved answer.
    public func profile() -> OnboardingProfile? {
        read()?.profile
    }

    /// Saves the role step's answer. Before onboarding ends the record
    /// keeps version 0, so it still counts as not done.
    public func saveProfile(_ profile: OnboardingProfile, now: Date = Date()) throws {
        var record = read() ?? Record(version: 0, completed: false, date: now)
        record.profile = profile
        try write(record)
    }
}
