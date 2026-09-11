public import CmuxMobileShellModel
public import Foundation

/// The minimum Mac app versions one iOS build accepts, fetched from
/// `GET /api/mobile-mac-compat` (authoritative, cached per origin and app
/// build) with
/// ``baked`` as the compiled-in fallback for devices that have never fetched.
///
/// Tiers are keyed by an inclusive minimum iOS marketing version; the tier
/// with the greatest `minIOSVersion` at or below the running app's version
/// applies. An app below every tier is unconstrained, and a payload this
/// build cannot fully parse is discarded (the previous policy stays), so a
/// bad remote edit can never brick pairing beyond what it explicitly states.
public struct MobileMacCompatPolicy: Equatable, Sendable {
    /// The tiers of the policy, ascending by ``Tier/minIOSVersion``.
    public let tiers: [Tier]

    /// Creates a policy from its tiers.
    ///
    /// - Parameter tiers: The tiers, ascending by minimum iOS version.
    public init(tiers: [Tier]) {
        self.tiers = tiers
    }

    /// The compiled-in fallback, mirroring the initial committed entries of
    /// `web/data/mobile-mac-compat.ts`. Keep the two in sync when editing:
    /// the remote list replaces this the first time a device fetches it.
    /// The fallback mirrors the protocol eras in
    /// `web/data/mobile-mac-compat.ts`: 0.64.17 for the original release
    /// transport, 0.64.20 for authenticated Iroh, and 0.64.23 for the rebuilt
    /// Iroh transport. The App Store lane stays at 0.64.23 in every tier. The
    /// BETA 1.0.4 build 20260817224846 is the last older-compatible build;
    /// the later INTERNAL 1.0.4 cut uses the rebuilt transport.
    public static let baked: MobileMacCompatPolicy = {
        guard let minIOS = MobileMacAppVersion(parsing: "1.0.0"),
              let maxIOS = MobileMacAppVersion(parsing: "1.0.3"),
              let irohIOS = MobileMacAppVersion(parsing: "1.0.4"),
              let nextIOS = MobileMacAppVersion(parsing: "1.0.5"),
              let legacyStableMin = MobileMacAppVersion(parsing: "0.64.17"),
              let irohStableMin = MobileMacAppVersion(parsing: "0.64.20"),
              let stableMin = MobileMacAppVersion(parsing: "0.64.23"),
              let nightlyBase = MobileMacAppVersion(parsing: "0.64.22")
        else {
            return MobileMacCompatPolicy(tiers: [])
        }
        let nightly = NightlyRequirement(
            minBaseVersion: nightlyBase,
            minBuild: 3_345_650_013_202
        )
        let devMin = MobileMacAppVersion(parsing: "0.64.0")!
        return MobileMacCompatPolicy(tiers: [
            Tier(
                minIOSVersion: minIOS,
                maxIOSVersion: maxIOS,
                stableMinVersion: stableMin,
                nightly: nightly,
                buildKinds: [
                    MobileBuildType.dev.token: Requirement(stableMinVersion: devMin),
                    MobileBuildType.beta.token: Requirement(stableMinVersion: legacyStableMin),
                    MobileBuildType.internal.token: Requirement(stableMinVersion: legacyStableMin),
                    MobileBuildType.demo.token: Requirement(stableMinVersion: legacyStableMin),
                    MobileBuildType.prod.token: Requirement(stableMinVersion: stableMin, nightly: nightly),
                ]
            ),
            Tier(
                minIOSVersion: irohIOS,
                maxIOSVersion: irohIOS,
                stableMinVersion: stableMin,
                nightly: nightly,
                buildKinds: [
                    MobileBuildType.dev.token: Requirement(stableMinVersion: devMin),
                    MobileBuildType.beta.token: Requirement(stableMinVersion: irohStableMin),
                    MobileBuildType.internal.token: Requirement(stableMinVersion: stableMin),
                    MobileBuildType.demo.token: Requirement(stableMinVersion: irohStableMin),
                    MobileBuildType.prod.token: Requirement(stableMinVersion: stableMin, nightly: nightly),
                ]
            ),
            Tier(
                minIOSVersion: nextIOS,
                stableMinVersion: stableMin,
                nightly: nightly,
                buildKinds: [
                    MobileBuildType.dev.token: Requirement(stableMinVersion: devMin),
                    MobileBuildType.beta.token: Requirement(stableMinVersion: stableMin),
                    MobileBuildType.internal.token: Requirement(stableMinVersion: stableMin),
                    MobileBuildType.demo.token: Requirement(stableMinVersion: stableMin),
                    MobileBuildType.prod.token: Requirement(stableMinVersion: stableMin, nightly: nightly),
                ]
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
        macAppVersion: String?,
        buildType: MobileBuildType = .prod
    ) -> Violation? {
        guard let tier = tier(forIOSVersion: iosVersion) else { return nil }
        let requirement = tier.buildKinds[buildType.token]
            ?? Requirement(stableMinVersion: tier.stableMinVersion, nightly: tier.nightly)
        let requirementDisplay: String
        switch channel {
        case .stable:
            requirementDisplay = requirement.stableMinVersion.description
        case .nightly:
            guard let nightly = requirement.nightly else { return nil }
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
            return stamp.base >= requirement.stableMinVersion ? nil : violation
        case .nightly:
            guard let nightly = requirement.nightly else { return nil }
            guard let build = stamp.nightlyBuild else { return violation }
            if stamp.base > nightly.minBaseVersion { return nil }
            if stamp.base < nightly.minBaseVersion { return violation }
            return build >= nightly.minBuild ? nil : violation
        }
    }

}

extension MobileMacCompatPolicy {
    /// Decodes the `GET /api/mobile-mac-compat` payload. Returns `nil` for a
    /// payload this build cannot FULLY parse: dropping unparseable entries
    /// could silently weaken the constraint, so the caller keeps the previous
    /// policy instead.
    ///
    /// An EMPTY entries list decodes successfully to a zero-tier policy and
    /// deliberately lifts every constraint: it is the remote kill switch.
    /// An app version the server does not cover must get NO Mac version
    /// limit — accidentally blocking every Mac is the failure mode this
    /// product explicitly chose to avoid, so retraction is expressed by
    /// serving no tiers, not by hiding the endpoint.
    public init?(decoding data: Data) {
        guard let payload = try? JSONDecoder().decode(MobileMacCompatRemoteList.self, from: data) else {
            return nil
        }
        var tiers: [Tier] = []
        tiers.reserveCapacity(payload.entries.count)
        var previousMinIOSVersion: MobileMacAppVersion?
        for entry in payload.entries {
            guard let minIOS = MobileMacAppVersion(parsing: entry.minIOSVersion) else { return nil }
            var buildKinds: [String: Requirement] = [:]
            if let remoteKinds = entry.buildKinds {
                for (kind, remote) in remoteKinds {
                    guard let stable = MobileMacAppVersion(parsing: remote.stableMinVersion) else { return nil }
                    var nightly: NightlyRequirement?
                    if let value = remote.nightly {
                        guard let base = MobileMacAppVersion(parsing: value.minBaseVersion), let build = UInt64(value.minBuild) else { return nil }
                        nightly = NightlyRequirement(minBaseVersion: base, minBuild: build)
                    }
                    buildKinds[kind] = Requirement(stableMinVersion: stable, nightly: nightly)
                }
            }
            let legacyStable = entry.stableMinVersion.flatMap(MobileMacAppVersion.init(parsing:))
            if entry.buildKinds != nil,
               let legacyStable,
               legacyStable != buildKinds[MobileBuildType.prod.token]?.stableMinVersion {
                return nil
            }
            let stableMin = legacyStable ?? buildKinds[MobileBuildType.prod.token]?.stableMinVersion
            guard let stableMin else { return nil }
            // The server publishes ascending, non-overwriting tiers. Reject
            // malformed responses at the trust boundary rather than caching a
            // range that could make an affected app version fail open.
            if let previousMinIOSVersion, minIOS <= previousMinIOSVersion {
                return nil
            }
            var maxIOS: MobileMacAppVersion?
            if let remoteMax = entry.maxIOSVersion {
                guard let parsedMax = MobileMacAppVersion(parsing: remoteMax) else {
                    return nil
                }
                guard parsedMax >= minIOS else { return nil }
                maxIOS = parsedMax
            }
            var nightly: NightlyRequirement?
            if let remoteNightly = entry.nightly {
                guard let base = MobileMacAppVersion(parsing: remoteNightly.minBaseVersion), let build = UInt64(remoteNightly.minBuild) else { return nil }
                nightly = NightlyRequirement(minBaseVersion: base, minBuild: build)
            }
            if entry.buildKinds != nil {
                guard let prod = buildKinds[MobileBuildType.prod.token] else { return nil }
                if let nightly, nightly != prod.nightly { return nil }
            }
            tiers.append(Tier(minIOSVersion: minIOS, maxIOSVersion: maxIOS, stableMinVersion: stableMin, nightly: nightly, buildKinds: buildKinds))
            previousMinIOSVersion = minIOS
        }
        self.init(tiers: tiers)
    }

}
