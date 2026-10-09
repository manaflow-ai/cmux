import CmuxNextOnboarding
import CmuxNextSettings
import Foundation

extension FirstRunGate.ConfigOrigin {
    /// Where cmux-next.json stands before `CmuxConfigFile.prepareDefaultURL`
    /// seeds it: the gate reads the seed source, not whether the file exists
    /// after seeding. Call it once per launch, before seeding.
    static func beforeSeeding(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Self {
        let next = CmuxConfigFile.defaultURL(home: home, environment: environment)
        if fileManager.fileExists(atPath: next.path) { return contents(of: next) }
        // An override is never seeded from the account's classic file.
        if let override = environment[CmuxConfigFile.overrideKey], !override.isEmpty { return .absent }
        let classic = next.deletingLastPathComponent().appendingPathComponent("cmux.json")
        return fileManager.fileExists(atPath: classic.path) ? .seededFromClassic : .absent
    }

    /// `.empty` for no text or an empty object (comments allowed); any other
    /// content, unreadable text included, is the user's.
    private static func contents(of url: URL) -> Self {
        guard let source = try? CmuxConfigFile.source(at: url) else { return .settings }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        guard case .object(let members)? = try? JSONC.parse(source) else { return .settings }
        return members.isEmpty ? .empty : .settings
    }
}
