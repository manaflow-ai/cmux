public import Foundation
public import Observation

private func entriesWithMinimumSupportedVersions(
    _ entries: [String: MobileMacListAuthState.Entry],
    stableMinimum: String?,
    nightlyMinimum: String?
) -> [String: MobileMacListAuthState.Entry] {
    return entries.mapValues { entry in
        var updated = entry
        updated.minimumSupportedVersion = stableMinimum
        updated.minimumSupportedNightlyVersion = nightlyMinimum
        return updated
    }
}

private func numericMacVersion(_ raw: String) -> [Int]? {
    let core = raw.split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty,
          parts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else { return nil }
    var values = parts.map { Int($0)! }
    while values.count < 3 { values.append(0) }
    return values
}

private func nightlyMacVersion(_ raw: String) -> (base: [Int], build: UInt64)? {
    let core = raw.split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
    let marker = "-nightly."
    guard let markerRange = core.range(of: marker),
          let base = numericMacVersion(String(core[..<markerRange.lowerBound]))
    else { return nil }
    let buildText = core[markerRange.upperBound...]
    guard !buildText.isEmpty,
          buildText.utf8.allSatisfy({ (48 ... 57).contains($0) }),
          let build = UInt64(buildText)
    else { return nil }
    return (base, build)
}

/// The phone's view of the account device list (the list-auth admission
/// authority), projected for UI.
///
/// Written by the irx composition on every applied directory fact and on
/// sign-out; read by the Computers surfaces to warn when a remembered Mac
/// build is below the current minimum or when the directory has no build for
/// that Mac yet. A missing build is treated as possibly too old until the Mac
/// advertises its version.
///
/// A process-wide shared instance is the seam here because the writer lives
/// in `cmuxFeature` (the transport composition) and the readers live in
/// `CmuxMobileShellUI`, packages with no injection path between them today.
@MainActor
@Observable
public final class MobileMacListAuthState {
    public struct Entry: Equatable, Sendable {
        /// Directory lifecycle state (active/seeded/stale/...), verbatim.
        public var status: String
        public var revoked: Bool
        /// Whether the lease the entry came from is currently fresh.
        public var isFresh: Bool
        /// Version reported by the Mac's control-plane hello, including an
        /// optional `+build` suffix.
        public var appVersion: String?
        /// Release lane reported by the Mac's control-plane hello. Nightly
        /// rows use the nightly counter floor instead of the stable floor.
        public var releaseTrack: String?
        /// Server-advertised minimum Mac version for this account.
        public var minimumSupportedVersion: String?
        /// Server-advertised minimum nightly stamp for this iOS build.
        public var minimumSupportedNightlyVersion: String?

        public init(
            status: String,
            revoked: Bool,
            isFresh: Bool,
            appVersion: String? = nil,
            minimumSupportedVersion: String? = nil,
            releaseTrack: String? = nil,
            minimumSupportedNightlyVersion: String? = nil
        ) {
            self.status = status
            self.revoked = revoked
            self.isFresh = isFresh
            self.appVersion = appVersion
            self.releaseTrack = releaseTrack
            self.minimumSupportedVersion = minimumSupportedVersion
            self.minimumSupportedNightlyVersion = minimumSupportedNightlyVersion
        }

        /// True when the applicable server floor is valid and the Mac is
        /// either missing or has an unparsable build version, or is below that
        /// floor. Nightly rows compare their base version and monotonic build
        /// counter against ``minimumSupportedNightlyVersion``. An unusable
        /// reported version cannot establish compatibility, so it is treated
        /// as possibly too old until a valid hello arrives.
        public var isOutdated: Bool {
            if isNightly {
                guard let minimumSupportedNightlyVersion,
                      let required = nightlyMacVersion(minimumSupportedNightlyVersion)
                else { return false }
                guard let appVersion,
                      let installed = nightlyMacVersion(appVersion)
                else { return true }
                if installed.base != required.base {
                    return installed.base.lexicographicallyPrecedes(required.base)
                }
                return installed.build < required.build
            }
            guard let minimumSupportedVersion,
                  let required = numericMacVersion(minimumSupportedVersion)
            else { return false }
            guard let appVersion else { return true }
            guard let installed = numericMacVersion(appVersion) else { return true }
            return installed.lexicographicallyPrecedes(required)
        }

        /// The floor to show in the warning for this row's release lane.
        public var requiredVersionDisplay: String? {
            guard isOutdated else { return nil }
            return isNightly ? minimumSupportedNightlyVersion : minimumSupportedVersion
        }

        private var isNightly: Bool {
            if let releaseTrack {
                return releaseTrack.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "nightly"
            }
            return appVersion?.contains("-nightly.") == true
        }

    }

    public static let shared = MobileMacListAuthState()

    /// Entries keyed by the Mac's endpoint ID hex (TLS identity).
    public private(set) var entriesByEndpointID: [String: Entry] = [:]
    /// The same entries keyed by the Mac's durable device id, the key the
    /// Computers rows carry.
    public private(set) var entriesByDeviceID: [String: Entry] = [:]
    /// Whether ANY device list has been received or restored this session.
    /// False on a fresh install pre-hello (the dial bootstrap window).
    public private(set) var hasSnapshot = false
    /// Account-level minimum Mac version from the latest directory fact.
    public private(set) var minimumSupportedMacVersion: String?
    /// Minimum nightly stamp for the current iOS build, when one applies.
    public private(set) var minimumSupportedNightlyMacVersion: String?

    /// The current iOS build's policy floor, when the shell has installed one.
    /// This takes precedence over the legacy directory fact because the same
    /// account can be viewed by multiple iOS builds with different floors.
    private var policyMinimumSupportedMacVersion: String?
    private var policyMinimumSupportedNightlyMacVersion: String?
    private var hasPolicyMinimumSupportedMacVersion = false

    public init() {}

    /// Replaces the directory projection and its account-level floor.
    ///
    /// A missing directory floor is authoritative and clears the prior
    /// directory value. The current iOS policy, when installed, remains the
    /// higher-priority source for both release lanes.
    public func replace(
        entriesByEndpointID: [String: Entry],
        entriesByDeviceID: [String: Entry],
        minimumSupportedMacVersion: String? = nil
    ) {
        let effectiveStableMinimum = hasPolicyMinimumSupportedMacVersion
            ? policyMinimumSupportedMacVersion
            : minimumSupportedMacVersion
        let effectiveNightlyMinimum = hasPolicyMinimumSupportedMacVersion
            ? policyMinimumSupportedNightlyMacVersion
            : nil
        self.entriesByEndpointID = entriesWithMinimumSupportedVersions(
            entriesByEndpointID,
            stableMinimum: effectiveStableMinimum,
            nightlyMinimum: effectiveNightlyMinimum
        )
        self.entriesByDeviceID = entriesWithMinimumSupportedVersions(
            entriesByDeviceID,
            stableMinimum: effectiveStableMinimum,
            nightlyMinimum: effectiveNightlyMinimum
        )
        self.minimumSupportedMacVersion = effectiveStableMinimum
        self.minimumSupportedNightlyMacVersion = effectiveNightlyMinimum
        hasSnapshot = true
    }

    /// Installs the minimum Mac version for this iOS build and reapplies it to
    /// already-projected rows. A `nil` value is an intentional fail-open policy
    /// with no tier for the running iOS version.
    public func applyPolicyMinimumSupportedMacVersion(_ minimum: String?) {
        let existingNightlyMinimum = hasPolicyMinimumSupportedMacVersion
            ? policyMinimumSupportedNightlyMacVersion
            : minimumSupportedNightlyMacVersion
        applyPolicyMinimumSupportedMacVersions(
            stable: minimum,
            nightly: existingNightlyMinimum
        )
    }

    /// Installs both release-lane floors for this iOS build and reapplies them
    /// to already-projected rows.
    public func applyPolicyMinimumSupportedMacVersions(
        stable: String?,
        nightly: String?
    ) {
        policyMinimumSupportedMacVersion = stable
        policyMinimumSupportedNightlyMacVersion = nightly
        hasPolicyMinimumSupportedMacVersion = true
        entriesByEndpointID = entriesWithMinimumSupportedVersions(
            entriesByEndpointID,
            stableMinimum: stable,
            nightlyMinimum: nightly
        )
        entriesByDeviceID = entriesWithMinimumSupportedVersions(
            entriesByDeviceID,
            stableMinimum: stable,
            nightlyMinimum: nightly
        )
        minimumSupportedMacVersion = stable
        minimumSupportedNightlyMacVersion = nightly
    }

    public func clear() {
        entriesByEndpointID = [:]
        entriesByDeviceID = [:]
        minimumSupportedMacVersion = nil
        minimumSupportedNightlyMacVersion = nil
        hasSnapshot = false
    }

    public func entry(endpointIDHex: String) -> Entry? {
        entriesByEndpointID[endpointIDHex]
    }

    public func entry(deviceID: String) -> Entry? {
        entriesByDeviceID[deviceID]
    }

    /// Whether the directory still has a seeded overlay for this Mac. This is
    /// retained for connection admission diagnostics; the user-facing warning
    /// is derived from `isOutdated`, including when the seeded row has no
    /// remembered version yet.
    public func isSeeded(deviceID: String) -> Bool {
        entriesByDeviceID[deviceID]?.status == "seeded"
    }
}
