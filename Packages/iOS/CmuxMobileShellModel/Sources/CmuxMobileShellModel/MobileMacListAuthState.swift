public import CMUXMobileCore
public import Foundation
public import Observation

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
            return MobileMacVersionCompatibility(
                appVersion: appVersion,
                releaseTrack: releaseTrack,
                stableMinimum: minimumSupportedVersion,
                nightlyMinimum: minimumSupportedNightlyVersion
            ).isOutdated
        }

        /// The floor to show in the warning for this row's release lane.
        public var requiredVersionDisplay: String? {
            MobileMacVersionCompatibility(
                appVersion: appVersion,
                releaseTrack: releaseTrack,
                stableMinimum: minimumSupportedVersion,
                nightlyMinimum: minimumSupportedNightlyVersion
            ).requiredVersionDisplay
        }

    }

    /// The complete identity of one account-directory entry. The account scope
    /// is owned by the runtime, which clears this state at its account boundary.
    public struct Identity: Hashable, Sendable {
        public let pairingID: String?
        public let endpointIDHex: String
        public let bindingID: String?
        public let identityGeneration: Int?

        public init(
            pairingID: String?,
            endpointIDHex: String,
            bindingID: String? = nil,
            identityGeneration: Int? = nil
        ) {
            self.pairingID = pairingID
            self.endpointIDHex = endpointIDHex
            self.bindingID = bindingID
            self.identityGeneration = identityGeneration
        }
    }

    public static let shared = MobileMacListAuthState()

    /// Every directory entry retains its app, endpoint, binding, and generation.
    public private(set) var entriesByIdentity: [Identity: Entry] = [:]
    public private(set) var hasSnapshot = false
    public private(set) var minimumSupportedMacVersion: String?
    public private(set) var minimumSupportedNightlyMacVersion: String?
    private var policyMinimumSupportedMacVersion: String?
    private var policyMinimumSupportedNightlyMacVersion: String?
    private var hasPolicyMinimumSupportedMacVersion = false

    public init() {}

    /// Replaces the directory atomically. A policy installed for the running
    /// iOS build takes precedence over the legacy directory minimum.
    public func replace(
        entriesByIdentity: [Identity: Entry],
        minimumSupportedMacVersion: String? = nil
    ) {
        self.entriesByIdentity = entriesByIdentity
        self.minimumSupportedMacVersion = hasPolicyMinimumSupportedMacVersion
            ? policyMinimumSupportedMacVersion : minimumSupportedMacVersion
        minimumSupportedNightlyMacVersion = hasPolicyMinimumSupportedMacVersion
            ? policyMinimumSupportedNightlyMacVersion : nil
        reapplyMinimums()
        hasSnapshot = true
    }

    public func applyPolicyMinimumSupportedMacVersion(_ minimum: String?) {
        applyPolicyMinimumSupportedMacVersions(
            stable: minimum,
            nightly: hasPolicyMinimumSupportedMacVersion
                ? policyMinimumSupportedNightlyMacVersion : minimumSupportedNightlyMacVersion
        )
    }

    public func applyPolicyMinimumSupportedMacVersions(stable: String?, nightly: String?) {
        policyMinimumSupportedMacVersion = stable
        policyMinimumSupportedNightlyMacVersion = nightly
        hasPolicyMinimumSupportedMacVersion = true
        minimumSupportedMacVersion = stable
        minimumSupportedNightlyMacVersion = nightly
        reapplyMinimums()
    }

    private func reapplyMinimums() {
        entriesByIdentity = entriesByIdentity.mapValues { entry in
            var updated = entry
            updated.minimumSupportedVersion = minimumSupportedMacVersion
            updated.minimumSupportedNightlyVersion = minimumSupportedNightlyMacVersion
            return updated
        }
    }

    public func clear() {
        entriesByIdentity = [:]
        minimumSupportedMacVersion = hasPolicyMinimumSupportedMacVersion
            ? policyMinimumSupportedMacVersion : nil
        minimumSupportedNightlyMacVersion = hasPolicyMinimumSupportedMacVersion
            ? policyMinimumSupportedNightlyMacVersion : nil
        hasSnapshot = false
    }

    /// Endpoint-only diagnostics refuse an ambiguous directory identity.
    public func entry(endpointIDHex: String) -> Entry? {
        uniqueEntry { $0.endpointIDHex == endpointIDHex }
    }

    /// Resolves the row's exact app instance and, when advertised, endpoint.
    /// A missing endpoint never falls back to another endpoint on the same Mac.
    /// Multiple candidate bindings/generations stay unverified until resolved.
    public func entry(pairingID: String, endpointIDHexes: Set<String> = []) -> Entry? {
        uniqueEntry { identity in
            if !endpointIDHexes.isEmpty {
                return endpointIDHexes.contains(identity.endpointIDHex)
                    && (identity.pairingID == nil || identity.pairingID == pairingID)
            }
            return identity.pairingID == pairingID
        }
    }

    /// Produces the version evidence for the same app/endpoint the row can dial.
    /// Missing or ambiguous directory records keep their own lane's minimum.
    public func compatibilityEntry(pairingID: String, routes: [CmxAttachRoute] = []) -> Entry {
        let endpointIDs = Set(routes.compactMap { route -> String? in
            guard case let .peer(identity, _) = route.endpoint else { return nil }
            return identity.endpointID
        })
        var result = entry(pairingID: pairingID, endpointIDHexes: endpointIDs)
            ?? Entry(status: "unknown", revoked: false, isFresh: false)
        let instance = CmxMacAppInstanceIdentity(id: pairingID)
        result.releaseTrack = instance.instanceTag == "nightly" ? "nightly" : "stable"
        result.minimumSupportedVersion = minimumSupportedMacVersion
        result.minimumSupportedNightlyVersion = minimumSupportedNightlyMacVersion
        return result
    }

    private func uniqueEntry(matching matches: (Identity) -> Bool) -> Entry? {
        var result: Entry?
        for (identity, entry) in entriesByIdentity where matches(identity) {
            guard result == nil else { return nil }
            result = entry
        }
        return result
    }

    public func isSeeded(pairingID: String) -> Bool {
        entry(pairingID: pairingID)?.status == "seeded"
    }
}
