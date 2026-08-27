// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let cTLError = try? JSONDecoder().decode(CTLError.self, from: jsonData)
//   let cTLDirectory = try? JSONDecoder().decode(CTLDirectory.self, from: jsonData)
//   let cTLHelloACK = try? JSONDecoder().decode(CTLHelloACK.self, from: jsonData)
//   let cTLHello = try? JSONDecoder().decode(CTLHello.self, from: jsonData)
//   let cTLHintUpdate = try? JSONDecoder().decode(CTLHintUpdate.self, from: jsonData)
//   let cTLMintRequest = try? JSONDecoder().decode(CTLMintRequest.self, from: jsonData)
//   let cTLPublishHint = try? JSONDecoder().decode(CTLPublishHint.self, from: jsonData)
//   let cTLRelayPasses = try? JSONDecoder().decode(CTLRelayPasses.self, from: jsonData)
//   let cTLSnapshotComplete = try? JSONDecoder().decode(CTLSnapshotComplete.self, from: jsonData)

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

public import Foundation

// MARK: - CTLError
public struct CTLError: Codable, Equatable {
    public let payload: CTLErrorPayload
    public let type: CTLErrorType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLErrorPayload, type: CTLErrorType, v: Int) {
        self.payload = payload
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLErrorPayload
public struct CTLErrorPayload: Codable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public enum CodingKeys: String, CodingKey {
        case code = "code"
        case message = "message"
        case retryable = "retryable"
    }

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public enum CTLErrorType: String, Codable, Equatable {
    case error = "error"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLDirectory
public struct CTLDirectory: Codable, Equatable {
    public let payload: CTLDirectoryPayload
    /// monotonic account route revision this fact reflects
    public let rev: Int
    public let type: CTLDirectoryType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case rev = "rev"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLDirectoryPayload, rev: Int, type: CTLDirectoryType, v: Int) {
        self.payload = payload
        self.rev = rev
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLDirectoryPayload
public struct CTLDirectoryPayload: Codable, Equatable {
    public let bindings: [Binding]
    public let grantVerificationKeys: [GrantVerificationKey]
    public let relayFleet: [String]
    public let routeContractVersion: Int

    public enum CodingKeys: String, CodingKey {
        case bindings = "bindings"
        case grantVerificationKeys = "grantVerificationKeys"
        case relayFleet = "relayFleet"
        case routeContractVersion = "routeContractVersion"
    }

    public init(bindings: [Binding], grantVerificationKeys: [GrantVerificationKey], relayFleet: [String], routeContractVersion: Int) {
        self.bindings = bindings
        self.grantVerificationKeys = grantVerificationKeys
        self.relayFleet = relayFleet
        self.routeContractVersion = routeContractVersion
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - Binding
public struct Binding: Codable, Equatable {
    public let bindingID: String
    public let clientNamespace: String
    public let deviceID: String?
    public let endpointID: String
    public let homeRelayURL: String?
    public let instanceTag: String?
    public let updatedAt: Date?

    public enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case clientNamespace = "clientNamespace"
        case deviceID = "deviceId"
        case endpointID = "endpointId"
        case homeRelayURL = "homeRelayUrl"
        case instanceTag = "instanceTag"
        case updatedAt = "updatedAt"
    }

    public init(bindingID: String, clientNamespace: String, deviceID: String?, endpointID: String, homeRelayURL: String?, instanceTag: String?, updatedAt: Date?) {
        self.bindingID = bindingID
        self.clientNamespace = clientNamespace
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.homeRelayURL = homeRelayURL
        self.instanceTag = instanceTag
        self.updatedAt = updatedAt
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - GrantVerificationKey
public struct GrantVerificationKey: Codable, Equatable {
    public let alg: String
    public let keyID: String
    public let publicKey: String

    public enum CodingKeys: String, CodingKey {
        case alg = "alg"
        case keyID = "keyId"
        case publicKey = "publicKey"
    }

    public init(alg: String, keyID: String, publicKey: String) {
        self.alg = alg
        self.keyID = keyID
        self.publicKey = publicKey
    }
}

public enum CTLDirectoryType: String, Codable, Equatable {
    case directory = "directory"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLHelloACK
public struct CTLHelloACK: Codable, Equatable {
    public let payload: CTLHelloACKPayload
    public let type: CTLHelloACKType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLHelloACKPayload, type: CTLHelloACKType, v: Int) {
        self.payload = payload
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLHelloACKPayload
public struct CTLHelloACKPayload: Codable, Equatable {
    /// rev the server resumed the delta stream from; null means full snapshot follows
    public let resumedFromRev: Int?
    public let sessionID: String

    public enum CodingKeys: String, CodingKey {
        case resumedFromRev = "resumedFromRev"
        case sessionID = "sessionId"
    }

    public init(resumedFromRev: Int?, sessionID: String) {
        self.resumedFromRev = resumedFromRev
        self.sessionID = sessionID
    }
}

public enum CTLHelloACKType: String, Codable, Equatable {
    case helloACK = "hello_ack"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLHello
public struct CTLHello: Codable, Equatable {
    public let payload: CTLHelloPayload
    public let type: CTLHelloType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLHelloPayload, type: CTLHelloType, v: Int) {
        self.payload = payload
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLHelloPayload
public struct CTLHelloPayload: Codable, Equatable {
    public let endpointID: String
    /// highest rev this client has on disk; server streams deltas after it, or a full snapshot
    /// when null/too old
    public let haveRev: Int?
    public let wantPasses: Bool

    public enum CodingKeys: String, CodingKey {
        case endpointID = "endpointId"
        case haveRev = "haveRev"
        case wantPasses = "wantPasses"
    }

    public init(endpointID: String, haveRev: Int?, wantPasses: Bool) {
        self.endpointID = endpointID
        self.haveRev = haveRev
        self.wantPasses = wantPasses
    }
}

public enum CTLHelloType: String, Codable, Equatable {
    case hello = "hello"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLHintUpdate
public struct CTLHintUpdate: Codable, Equatable {
    public let payload: CTLHintUpdatePayload
    /// monotonic account route revision this fact reflects
    public let rev: Int
    public let type: CTLHintUpdateType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case rev = "rev"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLHintUpdatePayload, rev: Int, type: CTLHintUpdateType, v: Int) {
        self.payload = payload
        self.rev = rev
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLHintUpdatePayload
public struct CTLHintUpdatePayload: Codable, Equatable {
    public let endpointID: String
    public let homeRelayURL: String
    public let updatedAt: Date?

    public enum CodingKeys: String, CodingKey {
        case endpointID = "endpointId"
        case homeRelayURL = "homeRelayUrl"
        case updatedAt = "updatedAt"
    }

    public init(endpointID: String, homeRelayURL: String, updatedAt: Date?) {
        self.endpointID = endpointID
        self.homeRelayURL = homeRelayURL
        self.updatedAt = updatedAt
    }
}

public enum CTLHintUpdateType: String, Codable, Equatable {
    case hintUpdate = "hint_update"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLMintRequest
public struct CTLMintRequest: Codable, Equatable {
    public let payload: CTLMintRequestPayload
    public let type: CTLMintRequestType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLMintRequestPayload, type: CTLMintRequestType, v: Int) {
        self.payload = payload
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLMintRequestPayload
public struct CTLMintRequestPayload: Codable, Equatable {
    public let endpointID: String
    /// Optional signed identity assertion (reserved for the source-of-truth migration; phase A
    /// authorizes via the bearer-authenticated socket and confirms hints by re-fetching
    /// discovery)
    public let proof: PurpleProof?

    public enum CodingKeys: String, CodingKey {
        case endpointID = "endpointId"
        case proof = "proof"
    }

    public init(endpointID: String, proof: PurpleProof?) {
        self.endpointID = endpointID
        self.proof = proof
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

/// Optional signed identity assertion (reserved for the source-of-truth migration; phase A
/// authorizes via the bearer-authenticated socket and confirms hints by re-fetching
/// discovery)
// MARK: - PurpleProof
public struct PurpleProof: Codable, Equatable {
    public let bindingID: String
    /// base64 Ed25519 signature by the endpoint key
    public let signature: String
    /// RFC3339 issue time; server enforces freshness window
    public let timestamp: String

    public enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case signature = "signature"
        case timestamp = "timestamp"
    }

    public init(bindingID: String, signature: String, timestamp: String) {
        self.bindingID = bindingID
        self.signature = signature
        self.timestamp = timestamp
    }
}

public enum CTLMintRequestType: String, Codable, Equatable {
    case mintRequest = "mint_request"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLPublishHint
public struct CTLPublishHint: Codable, Equatable {
    public let payload: CTLPublishHintPayload
    public let type: CTLPublishHintType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLPublishHintPayload, type: CTLPublishHintType, v: Int) {
        self.payload = payload
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLPublishHintPayload
public struct CTLPublishHintPayload: Codable, Equatable {
    public let endpointID: String
    public let homeRelayURL: String
    /// Optional signed identity assertion (reserved for the source-of-truth migration; phase A
    /// authorizes via the bearer-authenticated socket and confirms hints by re-fetching
    /// discovery)
    public let proof: FluffyProof?

    public enum CodingKeys: String, CodingKey {
        case endpointID = "endpointId"
        case homeRelayURL = "homeRelayUrl"
        case proof = "proof"
    }

    public init(endpointID: String, homeRelayURL: String, proof: FluffyProof?) {
        self.endpointID = endpointID
        self.homeRelayURL = homeRelayURL
        self.proof = proof
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

/// Optional signed identity assertion (reserved for the source-of-truth migration; phase A
/// authorizes via the bearer-authenticated socket and confirms hints by re-fetching
/// discovery)
// MARK: - FluffyProof
public struct FluffyProof: Codable, Equatable {
    public let bindingID: String
    /// base64 Ed25519 signature by the endpoint key
    public let signature: String
    /// RFC3339 issue time; server enforces freshness window
    public let timestamp: String

    public enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case signature = "signature"
        case timestamp = "timestamp"
    }

    public init(bindingID: String, signature: String, timestamp: String) {
        self.bindingID = bindingID
        self.signature = signature
        self.timestamp = timestamp
    }
}

public enum CTLPublishHintType: String, Codable, Equatable {
    case publishHint = "publish_hint"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLRelayPasses
public struct CTLRelayPasses: Codable, Equatable {
    public let payload: CTLRelayPassesPayload
    /// monotonic account route revision this fact reflects
    public let rev: Int
    public let type: CTLRelayPassesType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case rev = "rev"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLRelayPassesPayload, rev: Int, type: CTLRelayPassesType, v: Int) {
        self.payload = payload
        self.rev = rev
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLRelayPassesPayload
public struct CTLRelayPassesPayload: Codable, Equatable {
    public let endpointID: String
    public let passes: [Pass]

    public enum CodingKeys: String, CodingKey {
        case endpointID = "endpointId"
        case passes = "passes"
    }

    public init(endpointID: String, passes: [Pass]) {
        self.endpointID = endpointID
        self.passes = passes
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - Pass
public struct Pass: Codable, Equatable {
    public let expiresAt: Date
    public let generation: Int
    /// server-driven early-refresh point (expiry minus margin)
    public let refreshAfter: Date
    public let relayURL: String
    public let token: String

    public enum CodingKeys: String, CodingKey {
        case expiresAt = "expiresAt"
        case generation = "generation"
        case refreshAfter = "refreshAfter"
        case relayURL = "relayUrl"
        case token = "token"
    }

    public init(expiresAt: Date, generation: Int, refreshAfter: Date, relayURL: String, token: String) {
        self.expiresAt = expiresAt
        self.generation = generation
        self.refreshAfter = refreshAfter
        self.relayURL = relayURL
        self.token = token
    }
}

public enum CTLRelayPassesType: String, Codable, Equatable {
    case relayPasses = "relay_passes"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLSnapshotComplete
public struct CTLSnapshotComplete: Codable, Equatable {
    public let payload: CTLSnapshotCompletePayload
    /// monotonic account route revision this fact reflects
    public let rev: Int
    public let type: CTLSnapshotCompleteType
    /// control-plane protocol version, 1
    public let v: Int

    public enum CodingKeys: String, CodingKey {
        case payload = "payload"
        case rev = "rev"
        case type = "type"
        case v = "v"
    }

    public init(payload: CTLSnapshotCompletePayload, rev: Int, type: CTLSnapshotCompleteType, v: Int) {
        self.payload = payload
        self.rev = rev
        self.type = type
        self.v = v
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - CTLSnapshotCompletePayload
public struct CTLSnapshotCompletePayload: Codable, Equatable {

    public init() {
    }
}

public enum CTLSnapshotCompleteType: String, Codable, Equatable {
    case snapshotComplete = "snapshot_complete"
}
