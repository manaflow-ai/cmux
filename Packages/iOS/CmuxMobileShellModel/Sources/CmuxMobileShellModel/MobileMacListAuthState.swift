public import Foundation
public import Observation

/// The phone's view of the account device list (the list-auth admission
/// authority), projected for UI.
///
/// Written by the irx composition on every applied directory fact and on
/// sign-out; read by the Computers surfaces to warn about Macs the new
/// connection system has not verified yet (directory `status == "seeded"`:
/// a binding never confirmed by its own control-plane hello, i.e. a Mac
/// still running a pre-list-auth cmux).
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
        /// Server-advertised minimum Mac version for this account.
        public var minimumSupportedVersion: String?

        public init(
            status: String,
            revoked: Bool,
            isFresh: Bool,
            appVersion: String? = nil,
            minimumSupportedVersion: String? = nil
        ) {
            self.status = status
            self.revoked = revoked
            self.isFresh = isFresh
            self.appVersion = appVersion
            self.minimumSupportedVersion = minimumSupportedVersion
        }

        /// True only when both versions are known and the Mac is below the
        /// server floor. Malformed or channel-only values stay informational.
        public var isOutdated: Bool {
            guard let appVersion, let minimumSupportedVersion,
                  let installed = Self.numericVersion(appVersion),
                  let required = Self.numericVersion(minimumSupportedVersion)
            else { return false }
            return installed.lexicographicallyPrecedes(required)
        }

        private static func numericVersion(_ raw: String) -> [Int]? {
            let core = raw.split(separator: "+", maxSplits: 1).first.map(String.init) ?? raw
            let parts = core.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else { return nil }
            var values = parts.map { Int($0)! }
            while values.count < 3 { values.append(0) }
            return values
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

    public init() {}

    public func replace(
        entriesByEndpointID: [String: Entry],
        entriesByDeviceID: [String: Entry],
        minimumSupportedMacVersion: String? = nil
    ) {
        self.entriesByEndpointID = entriesByEndpointID
        self.entriesByDeviceID = entriesByDeviceID
        self.minimumSupportedMacVersion = minimumSupportedMacVersion
        hasSnapshot = true
    }

    public func clear() {
        entriesByEndpointID = [:]
        entriesByDeviceID = [:]
        minimumSupportedMacVersion = nil
        hasSnapshot = false
    }

    public func entry(endpointIDHex: String) -> Entry? {
        entriesByEndpointID[endpointIDHex]
    }

    public func entry(deviceID: String) -> Entry? {
        entriesByDeviceID[deviceID]
    }

    /// The Computers-row warning predicate: the Mac exists in the directory
    /// but was seeded by the account overlay and has never confirmed itself
    /// on the new connection system.
    public func isSeeded(deviceID: String) -> Bool {
        entriesByDeviceID[deviceID]?.status == "seeded"
    }
}
