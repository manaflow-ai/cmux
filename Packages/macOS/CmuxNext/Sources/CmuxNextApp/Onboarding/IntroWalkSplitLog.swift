import CmuxNextCompat
import CmuxNextOnboarding
import CmuxNextWindowRules
import Foundation
import os

/// Make cmux Yours' split over the Rust rules (`onboarding_walk_bundle`, `onboarding_walk_outcome`,
/// cmux-window-rules walk_split.rs): the install key is a random id made once and kept in this
/// Mac's preferences (never sent anywhere), and each walk's start and end is one JSON line in
/// `Application Support/<bundle id>/intro-walk/outcomes.jsonl` (each build its own, like the error journal), the records `walk_split::tally`
/// counts per bundle. Nothing here leaves the Mac.
@MainActor
final class IntroWalkSplitLog: IntroWalkSplitSource {
    static let installKeyPreference = "introWalkInstallKey"

    private let defaults: UserDefaults
    private let file: URL
    private let rules = WindowRules()

    init(defaults: UserDefaults = .standard,
         file: URL = NextSupport.applicationSupportDirectory()
             .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next", isDirectory: true)
             .appendingPathComponent("intro-walk/outcomes.jsonl")) {
        self.defaults = defaults
        self.file = file
    }

    /// This install's key: made once, the same every launch, so its bundle never reshuffles.
    var installKey: String {
        if let key = defaults.string(forKey: Self.installKeyPreference), !key.isEmpty { return key }
        let key = UUID().uuidString.lowercased()
        defaults.set(key, forKey: Self.installKeyPreference)
        return key
    }

    private struct BundleRequest: Encodable { var installKey: String }
    private struct BundleReply: Decodable { var id: String }
    private struct OutcomeRequest: Encodable { var bundle: String; var ending: IntroWalkEnding; var screen: Int }
    struct Outcome: Codable, Equatable {
        var version: Int
        var bundle: String
        var ending: IntroWalkEnding
        var screen: Int
    }

    func bundle() -> String? {
        rules.call("onboarding_walk_bundle", BundleRequest(installKey: installKey), as: BundleReply.self)?.id
    }

    func record(bundle: String, ending: IntroWalkEnding, screen: Int) {
        guard let outcome = rules.call("onboarding_walk_outcome",
                                       OutcomeRequest(bundle: bundle, ending: ending, screen: max(0, screen)),
                                       as: Outcome.self),
              var line = try? JSONEncoder().encode(outcome) else { return }
        line.append(0x0A)
        Self.log.info("intro walk \(ending.rawValue, privacy: .public) bundle \(bundle, privacy: .public) screen \(screen)")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file, options: .atomic)
            }
        } catch {
            Self.log.error("intro walk record not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The records written so far, oldest first (tests, the probe).
    func records() -> [Outcome] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(Outcome.self, from: Data($0)) }
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "intro-walk")
}
