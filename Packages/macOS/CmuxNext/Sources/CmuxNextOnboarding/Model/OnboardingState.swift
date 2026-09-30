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
    }

    /// True when onboarding for the current version was never finished or skipped.
    public func needsOnboarding() -> Bool {
        // concurrency-allow: nonisolated; the App reads it off the main thread at launch
        guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data) else { return true }
        return record.version < Self.currentVersion
    }

    /// Records that onboarding ended (`completed` false: skipped).
    public func markDone(completed: Bool, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = Record(version: Self.currentVersion, completed: completed, date: now)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}
