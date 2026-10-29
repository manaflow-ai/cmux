public import Foundation

/// The signed flags document the nightly publishes beside its notes (`notes/flags.json`, from the
/// reviewed `release-notes/next/flags.json`), read for its per-PR kill switches:
///
///     {"version": 1, "default": {"DisabledFeatures": ["pr-23456"]},
///      "cohorts": {"dev": {"DisabledFeatures": []}}}
///
/// A cohort's keys replace the default's, as cmux-tui's reader does (`feature_flags.rs`); the app's
/// cohort is its release ring (`updates.channel`). Only `pr-<N>` entries are kill switches; the
/// other names are cmux-tui's invite-wave features.
nonisolated public struct KillSwitchDocument: Equatable, Sendable {
    private let defaultKeys: [String]?
    private let cohortKeys: [String: [String]]

    /// Nil unless `data` is a version 1 document.
    public init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 1 else { return nil }
        func disabled(_ object: Any?) -> [String]? {
            ((object as? [String: Any])?["DisabledFeatures"] as? [Any])?.compactMap { $0 as? String }
        }
        defaultKeys = disabled(root["default"])
        var cohorts: [String: [String]] = [:]
        for (name, object) in root["cohorts"] as? [String: Any] ?? [:] {
            if let keys = disabled(object) { cohorts[name] = keys }
        }
        cohortKeys = cohorts
    }

    /// The `pr-<N>` switches this document turns off for `cohort`.
    public func off(cohort: String) -> Set<String> {
        Set((cohortKeys[cohort] ?? defaultKeys ?? []).filter(Self.isSwitch))
    }

    /// `pr-<N>`, N a positive number.
    static func isSwitch(_ key: String) -> Bool {
        guard key.hasPrefix("pr-") else { return false }
        let number = key.dropFirst(3)
        return !number.isEmpty && number.first != "0" && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }
}
