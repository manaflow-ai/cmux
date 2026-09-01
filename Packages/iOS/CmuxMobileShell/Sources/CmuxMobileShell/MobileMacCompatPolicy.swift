public import Foundation

/// A Mac build version stamp as reported through authenticated host status:
/// either a released dotted version (`0.64.22`) or a nightly stamp
/// (`0.64.22-nightly.3345650013201`, where the counter is the GitHub run id
/// plus a two-digit attempt and is therefore globally monotonic).
public struct MobileMacBuildVersionStamp: Equatable, Sendable {
    /// The dotted numeric base version.
    public let base: MobileMacAppVersion
    /// The monotonic nightly build counter, present only on nightly stamps.
    public let nightlyBuild: UInt64?

    /// Parses a reported marketing version, accepting the released and the
    /// nightly grammar only. Anything else (empty, custom suffixes) is `nil`.
    public init?(parsing string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let released = MobileMacAppVersion(parsing: trimmed) {
            base = released
            nightlyBuild = nil
            return
        }
        let marker = "-nightly."
        guard let markerRange = trimmed.range(of: marker),
              let parsedBase = MobileMacAppVersion(parsing: String(trimmed[..<markerRange.lowerBound]))
        else {
            return nil
        }
        let counter = trimmed[markerRange.upperBound...]
        guard !counter.isEmpty,
              counter.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let build = UInt64(counter)
        else {
            return nil
        }
        base = parsedBase
        nightlyBuild = build
    }
}

/// The minimum Mac app versions one iOS build accepts, fetched from
/// `GET /api/mobile-mac-compat` (authoritative, cached per origin) with
/// ``baked`` as the compiled-in fallback for devices that have never fetched.
///
/// Tiers are keyed by an inclusive minimum iOS marketing version; the tier
/// with the greatest `minIOSVersion` at or below the running app's version
/// applies. An app below every tier is unconstrained, and a payload this
/// build cannot fully parse is discarded (the previous policy stays), so a
/// bad remote edit can never brick pairing beyond what it explicitly states.
public struct MobileMacCompatPolicy: Equatable, Sendable {
    /// The minimum nightly-channel build for one tier.
    public struct NightlyRequirement: Equatable, Sendable {
        /// The nightly stamp's base version at the minimum.
        public let minBaseVersion: MobileMacAppVersion
        /// The minimum monotonic nightly build counter, applied only when the
        /// stamp's base equals ``minBaseVersion`` (a greater base is newer).
        public let minBuild: UInt64

        public init(minBaseVersion: MobileMacAppVersion, minBuild: UInt64) {
            self.minBaseVersion = minBaseVersion
            self.minBuild = minBuild
        }
    }

    /// One iOS-version tier and the Mac minimums it demands.
    public struct Tier: Equatable, Sendable {
        /// The inclusive minimum iOS marketing version this tier applies to.
        public let minIOSVersion: MobileMacAppVersion
        /// The optional inclusive maximum iOS marketing version. `nil` is
        /// open-ended, so one tier captures every version from its minimum
        /// upward without listing each patch release; a bound scopes the
        /// tier to a range (equal min and max pinpoints one version).
        public let maxIOSVersion: MobileMacAppVersion?
        /// The inclusive minimum stable-channel Mac marketing version.
        public let stableMinVersion: MobileMacAppVersion
        /// The minimum nightly-channel build; `nil` leaves nightly unconstrained.
        public let nightly: NightlyRequirement?

        public init(
            minIOSVersion: MobileMacAppVersion,
            maxIOSVersion: MobileMacAppVersion? = nil,
            stableMinVersion: MobileMacAppVersion,
            nightly: NightlyRequirement?
        ) {
            self.minIOSVersion = minIOSVersion
            self.maxIOSVersion = maxIOSVersion
            self.stableMinVersion = stableMinVersion
            self.nightly = nightly
        }
    }

    /// The Mac release channel a version constraint applies to.
    public enum Channel: Equatable, Sendable {
        case stable
        case nightly
    }

    /// Why a connected Mac was refused, carrying everything the failure copy
    /// needs: the channel, the Mac's reported version (nil when the Mac
    /// predates version reporting), and the tier minimum for that channel.
    public struct Violation: Equatable, Sendable {
        public let channel: Channel
        public let macAppVersion: String?
        /// The minimum version to present: the stable minimum, or the nightly
        /// minimum rendered in the nightly stamp grammar.
        public let requiredVersionDisplay: String
    }

    public let tiers: [Tier]

    public init(tiers: [Tier]) {
        self.tiers = tiers
    }

    /// The compiled-in fallback, mirroring the initial committed entries of
    /// `web/data/mobile-mac-compat.ts`. Keep the two in sync when editing:
    /// the remote list replaces this the first time a device fetches it.
    /// The tier starts at 1.0.0 so it covers the App Store lane (which ships
    /// as 1.0.0) as well as the 1.0.4 beta lane.
    public static let baked: MobileMacCompatPolicy = {
        guard let minIOS = MobileMacAppVersion(parsing: "1.0.0"),
              let stableMin = MobileMacAppVersion(parsing: "0.64.23"),
              let nightlyBase = MobileMacAppVersion(parsing: "0.64.22")
        else {
            return MobileMacCompatPolicy(tiers: [])
        }
        return MobileMacCompatPolicy(tiers: [
            Tier(
                minIOSVersion: minIOS,
                stableMinVersion: stableMin,
                nightly: NightlyRequirement(
                    minBaseVersion: nightlyBase,
                    minBuild: 3_345_650_013_202
                )
            ),
        ])
    }()

    /// The tier that applies to one iOS marketing version: the greatest
    /// `minIOSVersion` at or below it. `nil` — no Mac version limit at all —
    /// when the app predates every tier, or when the winning tier's
    /// `maxIOSVersion` excludes it (the server does not cover this app
    /// version, and no limit beats accidentally admitting no Mac).
    public func tier(forIOSVersion version: String) -> Tier? {
        guard let iosVersion = MobileMacAppVersion(parsing: version) else { return nil }
        guard let winner = tiers
            .filter({ $0.minIOSVersion <= iosVersion })
            .max(by: { $0.minIOSVersion < $1.minIOSVersion })
        else {
            return nil
        }
        if let maxIOSVersion = winner.maxIOSVersion, iosVersion > maxIOSVersion {
            return nil
        }
        return winner
    }

    /// Evaluates a constrained-channel Mac against the tier for this app
    /// version. Returns `nil` when the Mac satisfies the tier (or no tier
    /// applies); a ``Violation`` means the connection must be refused with
    /// update guidance.
    ///
    /// A missing or unparseable version on a constrained channel violates the
    /// tier: every Mac release this policy can name reports its version, so
    /// an absent version proves the Mac predates the minimum.
    public func violation(
        iosVersion: String,
        channel: Channel,
        macAppVersion: String?
    ) -> Violation? {
        guard let tier = tier(forIOSVersion: iosVersion) else { return nil }
        let requirementDisplay: String
        switch channel {
        case .stable:
            requirementDisplay = tier.stableMinVersion.description
        case .nightly:
            guard let nightly = tier.nightly else { return nil }
            requirementDisplay = "\(nightly.minBaseVersion)-nightly.\(nightly.minBuild)"
        }
        let reported = macAppVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let violation = Violation(
            channel: channel,
            macAppVersion: reported?.isEmpty == false ? reported : nil,
            requiredVersionDisplay: requirementDisplay
        )
        guard let reported, let stamp = MobileMacBuildVersionStamp(parsing: reported) else {
            return violation
        }
        switch channel {
        case .stable:
            // A nightly stamp on the stable channel is a mislabeled build;
            // fail closed rather than guessing which rule it satisfies.
            guard stamp.nightlyBuild == nil else { return violation }
            return stamp.base >= tier.stableMinVersion ? nil : violation
        case .nightly:
            guard let nightly = tier.nightly else { return nil }
            guard let build = stamp.nightlyBuild else { return violation }
            if stamp.base > nightly.minBaseVersion { return nil }
            if stamp.base < nightly.minBaseVersion { return violation }
            return build >= nightly.minBuild ? nil : violation
        }
    }

    /// Resolves the constrained channel for an authenticated Mac instance
    /// tag: `default` is the stable release lane and `nightly` the nightly
    /// lane. Every other tag (development tags, `rc`, `staging`) is outside
    /// this policy — those lanes are already gated by
    /// ``MobileMacBuildCompatibilityPolicy`` and rebuilt from source. A
    /// missing tag is the pre-0.64.18 stable release lane.
    public static func constrainedChannel(instanceTag: String?) -> Channel? {
        let normalized = instanceTag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case nil, "", "default":
            return .stable
        case "nightly":
            return .nightly
        default:
            return nil
        }
    }
}

extension MobileMacCompatPolicy {
    /// Decodes the `GET /api/mobile-mac-compat` payload. Returns `nil` for a
    /// payload this build cannot FULLY parse: dropping unparseable entries
    /// could silently weaken the constraint, so the caller keeps the previous
    /// policy instead.
    public static func decode(_ data: Data) -> MobileMacCompatPolicy? {
        guard let payload = try? JSONDecoder().decode(RemoteList.self, from: data) else {
            return nil
        }
        var tiers: [Tier] = []
        tiers.reserveCapacity(payload.entries.count)
        for entry in payload.entries {
            guard let minIOS = MobileMacAppVersion(parsing: entry.minIOSVersion),
                  let stableMin = MobileMacAppVersion(parsing: entry.stableMinVersion)
            else {
                return nil
            }
            var maxIOS: MobileMacAppVersion?
            if let remoteMax = entry.maxIOSVersion {
                guard let parsedMax = MobileMacAppVersion(parsing: remoteMax) else {
                    return nil
                }
                maxIOS = parsedMax
            }
            var nightly: NightlyRequirement?
            if let remoteNightly = entry.nightly {
                guard let base = MobileMacAppVersion(parsing: remoteNightly.minBaseVersion),
                      let build = UInt64(remoteNightly.minBuild)
                else {
                    return nil
                }
                nightly = NightlyRequirement(minBaseVersion: base, minBuild: build)
            }
            tiers.append(Tier(
                minIOSVersion: minIOS,
                maxIOSVersion: maxIOS,
                stableMinVersion: stableMin,
                nightly: nightly
            ))
        }
        return MobileMacCompatPolicy(tiers: tiers)
    }

    /// The wire shape of `web/data/mobile-mac-compat.ts`. Unknown fields are
    /// ignored so the payload can grow without breaking older clients.
    private struct RemoteList: Decodable {
        struct Entry: Decodable {
            let minIOSVersion: String
            let maxIOSVersion: String?
            let stableMinVersion: String
            let nightly: Nightly?
        }

        struct Nightly: Decodable {
            let minBaseVersion: String
            let minBuild: String
        }

        let entries: [Entry]
    }
}
