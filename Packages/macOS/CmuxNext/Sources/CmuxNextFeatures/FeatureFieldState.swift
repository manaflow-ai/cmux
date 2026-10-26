import CryptoKit
import Foundation

/// A launch's features as field data carries them (p12-perf-process.md section 3.9, "Field"): a hash of
/// every feature's value, and the features an input other than the channel default decided. Chrome
/// gives crash reports and UMA logs the active field-trial groups the same way, as hashed names plus
/// the trials themselves (components/variations/variations_crash_keys.cc,
/// components/variations/active_field_trials.cc).
///
/// Names only: a feature name is a registry name declared in code, a state is `on` or `off` and a
/// source is ``Feature/Source``'s wire name. Hang reports and Sentry carry it; `scripts/perf-lab/field.py`
/// groups the field rows of one build by ``hash``.
public nonisolated struct FeatureFieldState: Sendable, Equatable {
    /// One feature an override decided.
    public struct Entry: Sendable, Equatable, CustomStringConvertible {
        public let name: String
        public let isEnabled: Bool
        public let source: Feature.Source

        public init(name: String, isEnabled: Bool, source: Feature.Source) {
            self.name = name
            self.isEnabled = isEnabled
            self.source = source
        }

        /// `on` or `off`.
        public var state: String { isEnabled ? "on" : "off" }

        /// `name=on@remote`, the form of the Sentry tag.
        public var description: String { "\(name)=\(state)@\(source)" }
    }

    /// The number of hex digits of ``hash``.
    public static let hashLength = 16

    /// The first ``hashLength`` hex digits of SHA-256 over `name=on|off` lines of every feature, sorted
    /// by name: the value of every feature, so a default flip changes it while the overrides stay the same.
    /// The source is left out: one arm is what runs, whichever input chose it.
    public let hash: String
    /// The features whose source is not the channel default, sorted by name.
    public let nonDefault: [Entry]

    /// The state of `entries`, each feature with the value it runs with.
    public init(_ entries: [(feature: Feature, resolution: Feature.Resolution)]) {
        let sorted = entries.sorted { $0.feature.name < $1.feature.name }
        let lines = sorted.map { "\($0.feature.name)=\($0.resolution.isEnabled ? "on" : "off")\n" }.joined()
        hash = SHA256.hash(data: Data(lines.utf8)).prefix(Self.hashLength / 2).map { String(format: "%02x", $0) }.joined()
        nonDefault = sorted.compactMap { entry in
            entry.resolution.source == .channelDefault ? nil
                : Entry(name: entry.feature.name, isEnabled: entry.resolution.isEnabled, source: entry.resolution.source)
        }
    }
}

extension FeatureList {
    /// This list's ``FeatureFieldState``.
    public var fieldState: FeatureFieldState { FeatureFieldState(entries) }
}
