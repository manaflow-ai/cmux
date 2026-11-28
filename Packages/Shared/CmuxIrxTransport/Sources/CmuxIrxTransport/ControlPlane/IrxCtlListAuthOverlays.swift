public import Foundation

// Generated wire values contain only immutable value types; make that fact
// explicit so the actor's handler closures can receive decoded directory
// payloads without changing the schema-generated source.
extension Binding: @unchecked Sendable {}
extension CTLDirectory: @unchecked Sendable {}
extension CTLDirectoryPayload: @unchecked Sendable {}
extension GrantVerificationKey: @unchecked Sendable {}
extension PurpleMinimumSupportedVersion: @unchecked Sendable {}
extension ReleaseTrack: @unchecked Sendable {}
extension Status: @unchecked Sendable {}

// Hand-written OVERLAY models for the list-auth control-plane additions.
//
// The generated `CtlWireModels.swift` is owned by the schema pipeline and did
// not yet carry these fields when this file was written. These overlays
// decode the SAME frames tolerantly (every list-auth field optional, unknown
// keys ignored) so the client works against both old and new servers.
// RECONCILE: once the generated models gain issuedAt/ttlSeconds/status/
// revoked/clientInfo/ack, fold these onto the generated types and delete the
// duplicates here.

/// Directory fact overlay: the generated payload plus the list-auth lease
/// stamp and per-entry authorization state.
public struct IrxCtlDirectoryFact: Decodable, Equatable, Sendable {
    public struct Payload: Decodable, Equatable, Sendable {
        public var bindings: [Entry]
        /// Legacy directory fields retained so the compatibility handler can
        /// receive the complete pre-list-auth payload when strict decoding
        /// fails on omitted lease fields.
        public var grantVerificationKeys: [GrantVerificationKey]?
        public var relayFleet: [String]?
        public var routeContractVersion: Int?
        /// RFC3339 server stamp; absent against a pre-list-auth server.
        public var issuedAt: Date?
        public var ttlSeconds: Int?
        public var minimumSupportedVersion: IrxCtlMinimumSupportedVersion?
    }

    public struct Entry: Decodable, Equatable, Sendable {
        public var endpointID: String
        public var clientNamespace: String?
        public var deviceID: String?
        public var bindingID: String?
        public var instanceTag: String?
        public var homeRelayURL: String?
        public var status: String?
        public var revoked: Bool?
        public var appVersion: String?
        public var releaseTrack: String?
        public var capabilities: [String]?
        public var lastConfirmedAt: Date?
        public var updatedAt: Date?
        public var identityGeneration: Int?

        enum CodingKeys: String, CodingKey {
            case endpointID = "endpointId"
            case clientNamespace = "clientNamespace"
            case deviceID = "deviceId"
            case bindingID = "bindingId"
            case instanceTag = "instanceTag"
            case homeRelayURL = "homeRelayUrl"
            case status = "status"
            case revoked = "revoked"
            case appVersion = "appVersion"
            case releaseTrack = "releaseTrack"
            case capabilities = "capabilities"
            case lastConfirmedAt = "lastConfirmedAt"
            case updatedAt = "updatedAt"
            case identityGeneration = "identityGeneration"
        }
    }

    public var rev: Int
    public var payload: Payload
}

/// Optional per-platform floor the server may attach to a directory or a
/// hello-ack. Advisory for now; surfaced in journals only.
public struct IrxCtlMinimumSupportedVersion: Decodable, Equatable, Sendable {
    public var mac: String?
    public var ios: String?
}

/// Explicit freshness re-stamp. The server may send a dedicated `current`
/// frame, or extend `snapshot_complete` with `issuedAt`; both are decoded
/// through this shape (stamp accepted at the payload or the top level).
public struct IrxCtlFreshnessStamp: Decodable, Equatable, Sendable {
    private struct Payload: Decodable, Equatable, Sendable {
        var issuedAt: Date?
    }

    public var rev: Int
    public private(set) var issuedAt: Date?

    enum CodingKeys: String, CodingKey {
        case rev, issuedAt, payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rev = try container.decode(Int.self, forKey: .rev)
        let topLevel = try container.decodeIfPresent(Date.self, forKey: .issuedAt)
        let payload = try container.decodeIfPresent(Payload.self, forKey: .payload)
        issuedAt = topLevel ?? payload?.issuedAt
    }
}

/// Optional client identification attached to the control-plane hello so the
/// server can seed directory entries with platform/version/capabilities.
public struct IrxCtlClientInfo: Equatable, Sendable {
    public var deviceID: String
    /// "mac" | "ios"
    public var platform: String
    public var appVersion: String
    public var releaseTrack: String
    public var capabilities: [String]

    public init(
        deviceID: String,
        platform: String,
        appVersion: String,
        releaseTrack: String,
        capabilities: [String]
    ) {
        self.deviceID = deviceID
        self.platform = platform
        self.appVersion = appVersion
        self.releaseTrack = releaseTrack
        self.capabilities = capabilities
    }

    /// `"<CFBundleShortVersionString>+<CFBundleVersion>"`, the one-string
    /// wire form of version + build.
    public static func appVersionString(infoDictionary: [String: Any]?) -> String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }
}

/// Hello v2 wire frame: the generated hello fields plus optional client info.
/// Old servers ignore the extra keys.
struct IrxCtlHelloV2: Encodable {
    struct Payload: Encodable {
        var endpointId: String
        var haveRev: Int?
        var wantPasses: Bool
        var deviceId: String?
        var platform: String?
        var appVersion: String?
        var releaseTrack: String?
        var capabilities: [String]?
    }

    var v = 1
    var type = "hello"
    var payload: Payload

    init(
        endpointID: String,
        haveRev: Int?,
        wantPasses: Bool,
        clientInfo: IrxCtlClientInfo?
    ) {
        payload = Payload(
            endpointId: endpointID,
            haveRev: haveRev,
            wantPasses: wantPasses,
            deviceId: clientInfo?.deviceID,
            platform: clientInfo?.platform,
            appVersion: clientInfo?.appVersion,
            releaseTrack: clientInfo?.releaseTrack,
            capabilities: clientInfo?.capabilities
        )
    }
}

/// Hello-ack overlay for the list-auth additions; every field optional so an
/// old server's ack still decodes.
struct IrxCtlHelloAckOverlay: Decodable {
    struct Payload: Decodable {
        var serverCapabilities: [String]?
        var minimumSupportedVersion: IrxCtlMinimumSupportedVersion?
    }

    var payload: Payload?
}
