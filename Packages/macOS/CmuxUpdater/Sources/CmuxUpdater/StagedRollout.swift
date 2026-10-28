public import Foundation

/// A staged rollout of one appcast item: the share of installs a scheduled check offers it to.
///
/// The release operator writes `<cmux:rolloutPercent>P</cmux:rolloutPercent>` into the item
/// (`scripts/cmux-next/release/stage-rollout.py`, docs/cmux-next/release-rollout.md) and raises
/// it stage by stage once each stage's crash-free sessions pass. Chrome's updater does the same
/// on its server (Omaha's staged rollout fraction); cmux has no update server, so the install
/// decides from the published fraction and a seed of its own, as Sparkle's
/// `sparkle:phasedRolloutInterval` does with its `SUUpdateGroupIdentifier`. Sparkle's phases are
/// time-driven (one seventh of installs per interval) and cannot hold at a stage while a gate
/// fails; this percentage moves only when the operator moves it, and `0` halts.
///
/// - An item without the element is offered to every install (every feed before this).
/// - Each install falls in one of ``buckets`` per build, from its seed and the build's
///   `sparkle:version`: raising the percentage keeps every install that already had the build,
///   and each build reaches a different first share of installs.
/// - A value that is not a number from 0 through 100 (an optional `%` after it) holds the item,
///   so a broken edit never ships a build to everyone.
/// - Only a scheduled check is held. A check the person starts takes the newest build, as
///   Sparkle's own phased rollout lets a person's check through.
public struct StagedRollout: Sendable, Equatable {
    /// The appcast item element (`propertiesDictionary` key) that carries the percentage.
    public static let element = "cmux:rolloutPercent"
    /// The namespace URI the operator tool declares for the `cmux:` prefix.
    public static let namespace = "https://cmux.com/xml-namespaces/rollout"
    /// The `UserDefaults` key of this install's seed.
    public static let seedKey = "cmux.updates.stagedRolloutSeed"
    /// How many shares one build's installs are split into: 0.01 % each.
    public static let buckets = 10_000

    /// This install's random seed, drawn once and kept (``init(defaults:)``).
    public let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }

    /// The seed kept in `defaults`, drawn and stored on first use.
    public init(defaults: UserDefaults) {
        if let stored = defaults.string(forKey: Self.seedKey).flatMap(UInt64.init) {
            seed = stored
        } else {
            seed = UInt64.random(in: .min ... .max)
            defaults.set(String(seed), forKey: Self.seedKey)
        }
    }

    /// Where this install falls among the installs of `version`: 0 ..< ``buckets``.
    public func bucket(forVersion version: String) -> Int {
        // FNV-1a over the seed's bytes and the version's UTF-8, then SplitMix64's finalizer, so
        // nearby seeds and versions spread over every bucket.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let seedBytes = (0 ..< 8).map { UInt8(truncatingIfNeeded: seed >> (8 * $0)) }
        for byte in seedBytes + Array(version.utf8) {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        hash ^= hash >> 30
        hash &*= 0xbf58_476d_1ce4_e5b9
        hash ^= hash >> 27
        hash &*= 0x94d0_49bb_1331_11eb
        hash ^= hash >> 31
        return Int(hash % UInt64(Self.buckets))
    }

    /// The percentage `raw` names (`"25"`, `"2.5"`, `"25%"`), or nil when it is not a number from
    /// 0 through 100.
    public static func percent(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("%") { text.removeLast() }
        guard let value = Double(text), value.isFinite, (0 ... 100).contains(value) else { return nil }
        return value
    }

    /// Whether a scheduled check offers build `version` whose item carries `rawPercent` (nil: no
    /// element, offered to all).
    public func offers(version: String, rawPercent: String?) -> Bool {
        guard let rawPercent else { return true }
        guard let percent = Self.percent(rawPercent) else { return false }
        return Double(bucket(forVersion: version)) < percent * Double(Self.buckets) / 100
    }

    /// Whether a scheduled check offers `item`.
    public func offers(_ item: UpdateAppcastItem) -> Bool {
        offers(version: item.versionString, rawPercent: item.rolloutPercent)
    }
}
