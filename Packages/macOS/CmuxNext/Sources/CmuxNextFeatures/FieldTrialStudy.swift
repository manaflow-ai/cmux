import Foundation

/// One study of the signed flags document's `Studies` list: Chromium's
/// variations `Study` (components/variations/proto/study.proto) for one
/// feature, with its `filter` cut to channel and build range.
///
/// ```json
/// {"name": "cefLayerHosting-1", "feature": "cefLayerHosting",
///  "arms": [{"name": "on", "weight": 50, "state": "on"}, {"name": "control", "weight": 50, "state": "off"}],
///  "channel": "nightly", "min_build": "1200", "max_build": "1300"}
/// ```
///
/// `name` defaults to the feature; `channel` is one channel or a list and
/// defaults to `nightly`, so Release runs a study only when its channel
/// names `release`. Build bounds are inclusive and compared numerically.
public nonisolated struct FieldTrialStudy: Sendable, Hashable {
    /// One arm: Chrome's `Study.Experiment` with a `feature_association`.
    public nonisolated struct Arm: Sendable, Hashable {
        public let name: String
        /// The arm's share is `weight / totalWeight` (Chrome's `probability_weight`).
        public let weight: Int
        /// The feature's value in this arm (`state` `on` or `off`).
        public let isEnabled: Bool

        public init(name: String, weight: Int, isEnabled: Bool) {
            self.name = name
            self.weight = weight
            self.isEnabled = isEnabled
        }
    }

    /// The channels of a study that does not name any.
    public static let defaultChannels: Set<Feature.Channel> = [.nightly]
    /// The largest sum of a study's weights (keeps the arm math in range).
    public static let maxTotalWeight = 1_000_000

    /// The study name, hashed with the low entropy source to pick the arm.
    public let name: String
    /// The registry name of the feature the arms set.
    public let feature: String
    public let arms: [Arm]
    public let channels: Set<Feature.Channel>
    /// Inclusive lower build bound (`CFBundleVersion`), nil for none.
    public let minBuild: String?
    /// Inclusive upper build bound (`CFBundleVersion`), nil for none.
    public let maxBuild: String?
    public let totalWeight: Int
    /// The hash seed of ``name``: Chrome's per-trial randomization seed
    /// (Chrome takes a SHA-1 prefix; this is MurmurHash3 of the UTF-8 name).
    public let seed: UInt32

    /// A checked study. Names may not be empty or hold whitespace, `,`,
    /// `/` or `=` (the separators of the force list and report entries).
    public init(
        name: String? = nil,
        feature: String,
        arms: [Arm],
        channels: Set<Feature.Channel> = FieldTrialStudy.defaultChannels,
        minBuild: String? = nil,
        maxBuild: String? = nil
    ) throws(FieldTrialError) {
        let name = name ?? feature
        guard Self.isValidName(name) else { throw FieldTrialError.invalidName(name) }
        guard Self.isValidName(feature) else { throw FieldTrialError.invalidName(feature) }
        guard !arms.isEmpty else { throw FieldTrialError.noArms }
        guard !channels.isEmpty else { throw FieldTrialError.noChannel }
        for bound in [minBuild, maxBuild].compactMap({ $0 }) where !Self.isValidBuild(bound) {
            throw FieldTrialError.invalidBuild(bound)
        }
        var armNames: Set<String> = []
        var totalWeight = 0
        for arm in arms {
            guard Self.isValidName(arm.name) else { throw FieldTrialError.invalidName(arm.name) }
            guard armNames.insert(arm.name).inserted else { throw FieldTrialError.duplicateArm(arm.name) }
            guard arm.weight >= 0, arm.weight <= Self.maxTotalWeight - totalWeight else {
                throw FieldTrialError.invalidWeight(arm: arm.name)
            }
            totalWeight += arm.weight
        }
        guard totalWeight > 0 else { throw FieldTrialError.zeroTotalWeight }
        self.name = name
        self.feature = feature
        self.arms = arms
        self.channels = channels
        self.minBuild = minBuild
        self.maxBuild = maxBuild
        self.totalWeight = totalWeight
        seed = Self.murmurHash3(Array(name.utf8), seed: 0)
    }

    /// The arm named `name`, if the study has one.
    public func arm(named name: String) -> Arm? {
        arms.first { $0.name == name }
    }

    /// Why the study does not run on `channel` at `build`, or nil when it runs.
    public func exclusion(channel: Feature.Channel, build: String) -> FieldTrialExclusion? {
        guard channels.contains(channel) else { return .channel }
        if let minBuild, build.compare(minBuild, options: .numeric) == .orderedAscending { return .belowMinBuild }
        if let maxBuild, build.compare(maxBuild, options: .numeric) == .orderedDescending { return .aboveMaxBuild }
        return nil
    }

    /// The arm `entropy` picks: Chrome's `FieldTrial` group choice
    /// (base/metrics/field_trial.cc) on the normalized entropy of
    /// ``ordinal(of:)``.
    public func arm(for entropy: LowEntropySource) -> Arm {
        arm(atOrdinal: ordinal(of: entropy))
    }

    /// The arm of every low entropy value, indexed by value: one sort
    /// instead of ``arm(for:)``'s scan per value (lab tools, tests).
    public func armsByEntropy() -> [Arm] {
        let ranked = (0..<LowEntropySource.range).sorted { lhs, rhs in
            (Self.murmurHash16(seed: seed, lhs), lhs) < (Self.murmurHash16(seed: seed, rhs), rhs)
        }
        var arms = [Arm](repeating: self.arms[0], count: LowEntropySource.range)
        for (ordinal, value) in ranked.enumerated() {
            arms[value] = arm(atOrdinal: ordinal)
        }
        return arms
    }

    /// The rank of `entropy`'s hash among the hashes of every value, in
    /// `0..<LowEntropySource.range`: Chrome's
    /// `NormalizedMurmurHashEntropyProvider::GetEntropyForTrial`
    /// (components/variations/entropy_provider.cc), with ties ranked by
    /// value. The ranks of all values are `0..<range` once each, so each arm
    /// gets `weight / totalWeight` of the values, exact to one value per arm
    /// boundary, and the seed makes each study's split independent of every
    /// other study's.
    public func ordinal(of entropy: LowEntropySource) -> Int {
        let mine = Self.murmurHash16(seed: seed, entropy.value)
        var ordinal = 0
        for other in 0..<LowEntropySource.range {
            let hash = Self.murmurHash16(seed: seed, other)
            if hash < mine || (hash == mine && other < entropy.value) { ordinal += 1 }
        }
        return ordinal
    }

    private func arm(atOrdinal ordinal: Int) -> Arm {
        let bucket = ordinal * totalWeight / LowEntropySource.range
        var cumulative = 0
        for arm in arms {
            cumulative += arm.weight
            if bucket < cumulative { return arm }
        }
        return arms[arms.count - 1]
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.unicodeScalars.contains { scalar in
            scalar == "," || scalar == "/" || scalar == "=" || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    static func isValidBuild(_ build: String) -> Bool {
        !build.isEmpty && build.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || $0 == "." }
    }
}

extension FieldTrialStudy {
    /// MurmurHash3 x86 32-bit of `bytes` (Chrome's `VariationsMurmurHash`,
    /// components/variations/variations_murmur_hash.cc).
    public static func murmurHash3(_ bytes: [UInt8], seed: UInt32) -> UInt32 {
        var hash = seed
        let whole = bytes.count / 4 * 4
        var index = 0
        while index < whole {
            let block = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            hash ^= mixBlock(block)
            hash = (hash << 13 | hash >> 19) &* 5 &+ 0xe654_6b64
            index += 4
        }
        var tail: UInt32 = 0
        for offset in stride(from: bytes.count - whole - 1, through: 0, by: -1) {
            tail = tail << 8 | UInt32(bytes[whole + offset])
        }
        if bytes.count > whole { hash ^= mixBlock(tail) }
        hash ^= UInt32(truncatingIfNeeded: bytes.count)
        return finalMix(hash)
    }

    /// MurmurHash3 of `value` as two little-endian bytes (Chrome's
    /// `VariationsMurmurHash::Hash16`).
    static func murmurHash16(seed: UInt32, _ value: Int) -> UInt32 {
        finalMix(seed ^ mixBlock(UInt32(truncatingIfNeeded: value) & 0xffff) ^ 2)
    }

    private static func mixBlock(_ block: UInt32) -> UInt32 {
        let scrambled = block &* 0xcc9e_2d51
        return (scrambled << 15 | scrambled >> 17) &* 0x1b87_3593
    }

    private static func finalMix(_ value: UInt32) -> UInt32 {
        var hash = value
        hash ^= hash >> 16
        hash = hash &* 0x85eb_ca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2_ae35
        hash ^= hash >> 16
        return hash
    }
}

/// Why a study's filter leaves it out of this build (not an error).
public nonisolated enum FieldTrialExclusion: Sendable, Hashable {
    /// The study does not name this build's channel.
    case channel
    /// The build is below `min_build`.
    case belowMinBuild
    /// The build is above `max_build`.
    case aboveMaxBuild
}
