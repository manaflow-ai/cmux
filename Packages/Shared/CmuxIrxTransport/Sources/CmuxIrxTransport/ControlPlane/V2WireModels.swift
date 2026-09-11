// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let v2Challenge = try? JSONDecoder().decode(V2Challenge.self, from: jsonData)
//   let v2DeliveryReceipt = try? JSONDecoder().decode(V2DeliveryReceipt.self, from: jsonData)
//   let v2DeviceDescriptor = try? JSONDecoder().decode(V2DeviceDescriptor.self, from: jsonData)
//   let v2DeviceMetadata = try? JSONDecoder().decode(V2DeviceMetadata.self, from: jsonData)
//   let v2DeviceProof = try? JSONDecoder().decode(V2DeviceProof.self, from: jsonData)
//   let v2DeviceRecord = try? JSONDecoder().decode(V2DeviceRecord.self, from: jsonData)
//   let v2Directory = try? JSONDecoder().decode(V2Directory.self, from: jsonData)
//   let v2Identity = try? JSONDecoder().decode(V2Identity.self, from: jsonData)
//   let v2InboundPeerPermission = try? JSONDecoder().decode(V2InboundPeerPermission.self, from: jsonData)
//   let v2Permission = try? JSONDecoder().decode(V2Permission.self, from: jsonData)
//   let v2RelayCredential = try? JSONDecoder().decode(V2RelayCredential.self, from: jsonData)
//   let v2Ticket = try? JSONDecoder().decode(V2Ticket.self, from: jsonData)
//   let v2AcknowledgementRequest = try? JSONDecoder().decode(V2AcknowledgementRequest.self, from: jsonData)
//   let v2ChallengeRequest = try? JSONDecoder().decode(V2ChallengeRequest.self, from: jsonData)
//   let v2DirectoryRequest = try? JSONDecoder().decode(V2DirectoryRequest.self, from: jsonData)
//   let v2GoodbyeRequest = try? JSONDecoder().decode(V2GoodbyeRequest.self, from: jsonData)
//   let v2MetadataRequest = try? JSONDecoder().decode(V2MetadataRequest.self, from: jsonData)
//   let v2PermissionRequest = try? JSONDecoder().decode(V2PermissionRequest.self, from: jsonData)
//   let v2PreferencesRequest = try? JSONDecoder().decode(V2PreferencesRequest.self, from: jsonData)
//   let v2RegisterRequest = try? JSONDecoder().decode(V2RegisterRequest.self, from: jsonData)
//   let v2RelayRequest = try? JSONDecoder().decode(V2RelayRequest.self, from: jsonData)
//   let v2RevokeRequest = try? JSONDecoder().decode(V2RevokeRequest.self, from: jsonData)
//   let v2SocketSetup = try? JSONDecoder().decode(V2SocketSetup.self, from: jsonData)
//   let v2TicketRequest = try? JSONDecoder().decode(V2TicketRequest.self, from: jsonData)
//   let v2ChallengeResponse = try? JSONDecoder().decode(V2ChallengeResponse.self, from: jsonData)
//   let v2ChangedResponse = try? JSONDecoder().decode(V2ChangedResponse.self, from: jsonData)
//   let v2CompletedResponse = try? JSONDecoder().decode(V2CompletedResponse.self, from: jsonData)
//   let v2DirectoryResponse = try? JSONDecoder().decode(V2DirectoryResponse.self, from: jsonData)
//   let v2ErrorCode = try? JSONDecoder().decode(V2ErrorCode.self, from: jsonData)
//   let v2ErrorResponse = try? JSONDecoder().decode(V2ErrorResponse.self, from: jsonData)
//   let v2ReadyResponse = try? JSONDecoder().decode(V2ReadyResponse.self, from: jsonData)
//   let v2RegisteredResponse = try? JSONDecoder().decode(V2RegisteredResponse.self, from: jsonData)
//   let v2RelayResponse = try? JSONDecoder().decode(V2RelayResponse.self, from: jsonData)
//   let v2RevokedResponse = try? JSONDecoder().decode(V2RevokedResponse.self, from: jsonData)
//   let v2TicketResponse = try? JSONDecoder().decode(V2TicketResponse.self, from: jsonData)
//   let v2Platform = try? JSONDecoder().decode(V2Platform.self, from: jsonData)

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

import Foundation

// MARK: - V2AcknowledgementRequest
public struct V2AcknowledgementRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let schemaID: V2AcknowledgementRequestSchemaID
    public let sequence: Int
    public let token: String

    public enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case schemaID = "schemaId"
        case sequence = "sequence"
        case token = "token"
    }

    public init(requestID: String, schemaID: V2AcknowledgementRequestSchemaID, sequence: Int, token: String) {
        self.requestID = requestID
        self.schemaID = schemaID
        self.sequence = sequence
        self.token = token
    }
}

public enum V2AcknowledgementRequestSchemaID: String, Codable, Equatable, Sendable {
    case sessionACKV1 = "session.ack.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2ChallengeRequest
public struct V2ChallengeRequest: Codable, Equatable, Sendable {
    public let device: V2DeviceDescriptor
    public let requestID: String
    public let schemaID: V2ChallengeRequestSchemaID

    public enum CodingKeys: String, CodingKey {
        case device = "device"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(device: V2DeviceDescriptor, requestID: String, schemaID: V2ChallengeRequestSchemaID) {
        self.device = device
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2DeviceDescriptor
public struct V2DeviceDescriptor: Codable, Equatable, Sendable {
    public let endpointID: String
    public let identity: V2Identity
    public let identityGeneration: Int
    public let metadata: V2DeviceMetadata

    public enum CodingKeys: String, CodingKey {
        case endpointID = "endpointId"
        case identity = "identity"
        case identityGeneration = "identityGeneration"
        case metadata = "metadata"
    }

    public init(endpointID: String, identity: V2Identity, identityGeneration: Int, metadata: V2DeviceMetadata) {
        self.endpointID = endpointID
        self.identity = identity
        self.identityGeneration = identityGeneration
        self.metadata = metadata
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2Identity
public struct V2Identity: Codable, Equatable, Sendable {
    public let appNamespace: String
    public let buildTag: String
    public let deviceID: String
    public let environment: String
    public let projectID: String
    public let teamID: String
    public let userID: String

    public enum CodingKeys: String, CodingKey {
        case appNamespace = "appNamespace"
        case buildTag = "buildTag"
        case deviceID = "deviceId"
        case environment = "environment"
        case projectID = "projectId"
        case teamID = "teamId"
        case userID = "userId"
    }

    public init(appNamespace: String, buildTag: String, deviceID: String, environment: String, projectID: String, teamID: String, userID: String) {
        self.appNamespace = appNamespace
        self.buildTag = buildTag
        self.deviceID = deviceID
        self.environment = environment
        self.projectID = projectID
        self.teamID = teamID
        self.userID = userID
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2DeviceMetadata
public struct V2DeviceMetadata: Codable, Equatable, Sendable {
    public let appVersion: String
    public let capabilities: [String]
    public let displayName: String
    public let pairingEnabled: Bool
    public let platform: V2Platform
    public let relayURLs: [String]

    public enum CodingKeys: String, CodingKey {
        case appVersion = "appVersion"
        case capabilities = "capabilities"
        case displayName = "displayName"
        case pairingEnabled = "pairingEnabled"
        case platform = "platform"
        case relayURLs = "relayURLs"
    }

    public init(appVersion: String, capabilities: [String], displayName: String, pairingEnabled: Bool, platform: V2Platform, relayURLs: [String]) {
        self.appVersion = appVersion
        self.capabilities = capabilities
        self.displayName = displayName
        self.pairingEnabled = pairingEnabled
        self.platform = platform
        self.relayURLs = relayURLs
    }
}

public enum V2Platform: String, Codable, Equatable, Sendable {
    case ios = "ios"
    case mac = "mac"
}

public enum V2ChallengeRequestSchemaID: String, Codable, Equatable, Sendable {
    case challengeRequestV1 = "challenge.request.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2DirectoryRequest
public struct V2DirectoryRequest: Codable, Equatable, Sendable {
    public let cursor: String?
    public let haveRevision: Int?
    public let requestID: String
    public let schemaID: V2DirectoryRequestSchemaID

    public enum CodingKeys: String, CodingKey {
        case cursor = "cursor"
        case haveRevision = "haveRevision"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(cursor: String? = nil, haveRevision: Int? = nil, requestID: String, schemaID: V2DirectoryRequestSchemaID) {
        self.cursor = cursor
        self.haveRevision = haveRevision
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

public enum V2DirectoryRequestSchemaID: String, Codable, Equatable, Sendable {
    case directoryRequestV1 = "directory.request.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2GoodbyeRequest
public struct V2GoodbyeRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let schemaID: V2GoodbyeRequestSchemaID

    public enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(requestID: String, schemaID: V2GoodbyeRequestSchemaID) {
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

public enum V2GoodbyeRequestSchemaID: String, Codable, Equatable, Sendable {
    case sessionGoodbyeV1 = "session.goodbye.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2MetadataRequest
public struct V2MetadataRequest: Codable, Equatable, Sendable {
    public let metadata: V2DeviceMetadata
    public let requestID: String
    public let schemaID: V2MetadataRequestSchemaID

    public enum CodingKeys: String, CodingKey {
        case metadata = "metadata"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(metadata: V2DeviceMetadata, requestID: String, schemaID: V2MetadataRequestSchemaID) {
        self.metadata = metadata
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

public enum V2MetadataRequestSchemaID: String, Codable, Equatable, Sendable {
    case deviceMetadataV1 = "device.metadata.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2PermissionRequest
public struct V2PermissionRequest: Codable, Equatable, Sendable {
    public let permission: V2Permission
    public let requestID: String
    public let schemaID: V2PermissionRequestSchemaID

    public enum CodingKeys: String, CodingKey {
        case permission = "permission"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(permission: V2Permission, requestID: String, schemaID: V2PermissionRequestSchemaID) {
        self.permission = permission
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2Permission
public struct V2Permission: Codable, Equatable, Sendable {
    public let connect: Bool
    public let deviceRecordID: String
    public let manage: Bool
    public let subjectUserID: String

    public enum CodingKeys: String, CodingKey {
        case connect = "connect"
        case deviceRecordID = "deviceRecordId"
        case manage = "manage"
        case subjectUserID = "subjectUserId"
    }

    public init(connect: Bool, deviceRecordID: String, manage: Bool, subjectUserID: String) {
        self.connect = connect
        self.deviceRecordID = deviceRecordID
        self.manage = manage
        self.subjectUserID = subjectUserID
    }
}

public enum V2PermissionRequestSchemaID: String, Codable, Equatable, Sendable {
    case permissionUpdateV1 = "permission.update.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2PreferencesRequest
public struct V2PreferencesRequest: Codable, Equatable, Sendable {
    public let expectedRevision: Int
    public let relayURLs: [String]
    public let requestID: String
    public let schemaID: V2PreferencesRequestSchemaID

    public enum CodingKeys: String, CodingKey {
        case expectedRevision = "expectedRevision"
        case relayURLs = "relayURLs"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(expectedRevision: Int, relayURLs: [String], requestID: String, schemaID: V2PreferencesRequestSchemaID) {
        self.expectedRevision = expectedRevision
        self.relayURLs = relayURLs
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

public enum V2PreferencesRequestSchemaID: String, Codable, Equatable, Sendable {
    case preferencesUpdateV1 = "preferences.update.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2RegisterRequest
public struct V2RegisterRequest: Codable, Equatable, Sendable {
    public let challengeID: String
    public let device: V2DeviceDescriptor
    public let nonce: String
    public let requestID: String
    public let schemaID: V2RegisterRequestSchemaID
    public let signature: String

    public enum CodingKeys: String, CodingKey {
        case challengeID = "challengeId"
        case device = "device"
        case nonce = "nonce"
        case requestID = "requestId"
        case schemaID = "schemaId"
        case signature = "signature"
    }

    public init(challengeID: String, device: V2DeviceDescriptor, nonce: String, requestID: String, schemaID: V2RegisterRequestSchemaID, signature: String) {
        self.challengeID = challengeID
        self.device = device
        self.nonce = nonce
        self.requestID = requestID
        self.schemaID = schemaID
        self.signature = signature
    }
}

public enum V2RegisterRequestSchemaID: String, Codable, Equatable, Sendable {
    case deviceRegisterV1 = "device.register.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2RelayRequest
public struct V2RelayRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let schemaID: V2RelayRequestSchemaID

    public enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(requestID: String, schemaID: V2RelayRequestSchemaID) {
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

public enum V2RelayRequestSchemaID: String, Codable, Equatable, Sendable {
    case relayRequestV1 = "relay.request.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2RevokeRequest
public struct V2RevokeRequest: Codable, Equatable, Sendable {
    public let deviceRecordID: String
    public let requestID: String
    public let schemaID: V2RevokeRequestSchemaID

    public enum CodingKeys: String, CodingKey {
        case deviceRecordID = "deviceRecordId"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(deviceRecordID: String, requestID: String, schemaID: V2RevokeRequestSchemaID) {
        self.deviceRecordID = deviceRecordID
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

public enum V2RevokeRequestSchemaID: String, Codable, Equatable, Sendable {
    case deviceRevokeV1 = "device.revoke.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2SocketSetup
public struct V2SocketSetup: Codable, Equatable, Sendable {
    public let device: V2DeviceDescriptor
    public let haveRevision: Int?
    public let proof: V2DeviceProof?
    public let requestID: String
    public let schemaID: V2SocketSetupSchemaID

    public enum CodingKeys: String, CodingKey {
        case device = "device"
        case haveRevision = "haveRevision"
        case proof = "proof"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(device: V2DeviceDescriptor, haveRevision: Int? = nil, proof: V2DeviceProof? = nil, requestID: String, schemaID: V2SocketSetupSchemaID) {
        self.device = device
        self.haveRevision = haveRevision
        self.proof = proof
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2DeviceProof
public struct V2DeviceProof: Codable, Equatable, Sendable {
    public let issuedAt: Int
    public let nonce: String
    public let requestID: String
    public let signature: String

    public enum CodingKeys: String, CodingKey {
        case issuedAt = "issuedAt"
        case nonce = "nonce"
        case requestID = "requestId"
        case signature = "signature"
    }

    public init(issuedAt: Int, nonce: String, requestID: String, signature: String) {
        self.issuedAt = issuedAt
        self.nonce = nonce
        self.requestID = requestID
        self.signature = signature
    }
}

public enum V2SocketSetupSchemaID: String, Codable, Equatable, Sendable {
    case sessionOpenV1 = "session.open.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2TicketRequest
public struct V2TicketRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let schemaID: V2TicketRequestSchemaID
    public let stackAccessToken: String

    public enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case schemaID = "schemaId"
        case stackAccessToken = "stackAccessToken"
    }

    public init(requestID: String, schemaID: V2TicketRequestSchemaID, stackAccessToken: String) {
        self.requestID = requestID
        self.schemaID = schemaID
        self.stackAccessToken = stackAccessToken
    }
}

public enum V2TicketRequestSchemaID: String, Codable, Equatable, Sendable {
    case ticketRequestV1 = "ticket.request.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2ChallengeResponse
public struct V2ChallengeResponse: Codable, Equatable, Sendable {
    public let challenge: V2Challenge
    public let deliveryReceipt: V2DeliveryReceipt?
    public let requestID: String
    public let schemaID: V2ChallengeResponseSchemaID

    public enum CodingKeys: String, CodingKey {
        case challenge = "challenge"
        case deliveryReceipt = "deliveryReceipt"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(challenge: V2Challenge, deliveryReceipt: V2DeliveryReceipt? = nil, requestID: String, schemaID: V2ChallengeResponseSchemaID) {
        self.challenge = challenge
        self.deliveryReceipt = deliveryReceipt
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2Challenge
public struct V2Challenge: Codable, Equatable, Sendable {
    public let challengeID: String
    public let expiresAt: Int
    public let nonce: String
    public let payloadHash: String

    public enum CodingKeys: String, CodingKey {
        case challengeID = "challengeId"
        case expiresAt = "expiresAt"
        case nonce = "nonce"
        case payloadHash = "payloadHash"
    }

    public init(challengeID: String, expiresAt: Int, nonce: String, payloadHash: String) {
        self.challengeID = challengeID
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.payloadHash = payloadHash
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2DeliveryReceipt
public struct V2DeliveryReceipt: Codable, Equatable, Sendable {
    public let sequence: Int
    public let token: String

    public enum CodingKeys: String, CodingKey {
        case sequence = "sequence"
        case token = "token"
    }

    public init(sequence: Int, token: String) {
        self.sequence = sequence
        self.token = token
    }
}

public enum V2ChallengeResponseSchemaID: String, Codable, Equatable, Sendable {
    case challengeResultV1 = "challenge.result.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2ChangedResponse
public struct V2ChangedResponse: Codable, Equatable, Sendable {
    public let deliveryReceipt: V2DeliveryReceipt?
    public let revision: Int
    public let schemaID: V2ChangedResponseSchemaID
    public let teamID: String

    public enum CodingKeys: String, CodingKey {
        case deliveryReceipt = "deliveryReceipt"
        case revision = "revision"
        case schemaID = "schemaId"
        case teamID = "teamId"
    }

    public init(deliveryReceipt: V2DeliveryReceipt? = nil, revision: Int, schemaID: V2ChangedResponseSchemaID, teamID: String) {
        self.deliveryReceipt = deliveryReceipt
        self.revision = revision
        self.schemaID = schemaID
        self.teamID = teamID
    }
}

public enum V2ChangedResponseSchemaID: String, Codable, Equatable, Sendable {
    case directoryChangedV1 = "directory.changed.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2CompletedResponse
public struct V2CompletedResponse: Codable, Equatable, Sendable {
    public let deliveryReceipt: V2DeliveryReceipt?
    public let requestID: String
    public let revision: Int
    public let schemaID: V2CompletedResponseSchemaID

    public enum CodingKeys: String, CodingKey {
        case deliveryReceipt = "deliveryReceipt"
        case requestID = "requestId"
        case revision = "revision"
        case schemaID = "schemaId"
    }

    public init(deliveryReceipt: V2DeliveryReceipt? = nil, requestID: String, revision: Int, schemaID: V2CompletedResponseSchemaID) {
        self.deliveryReceipt = deliveryReceipt
        self.requestID = requestID
        self.revision = revision
        self.schemaID = schemaID
    }
}

public enum V2CompletedResponseSchemaID: String, Codable, Equatable, Sendable {
    case operationCompletedV1 = "operation.completed.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2DirectoryResponse
public struct V2DirectoryResponse: Codable, Equatable, Sendable {
    public let deliveryReceipt: V2DeliveryReceipt?
    public let directory: V2Directory
    public let requestID: String
    public let schemaID: V2DirectoryResponseSchemaID

    public enum CodingKeys: String, CodingKey {
        case deliveryReceipt = "deliveryReceipt"
        case directory = "directory"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(deliveryReceipt: V2DeliveryReceipt? = nil, directory: V2Directory, requestID: String, schemaID: V2DirectoryResponseSchemaID) {
        self.deliveryReceipt = deliveryReceipt
        self.directory = directory
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2Directory
public struct V2Directory: Codable, Equatable, Sendable {
    public let devices: [V2DeviceRecord]
    public let inboundPeers: [V2InboundPeerPermission]?
    public let issuedAt: Int
    public let nextCursor: String?
    public let permissionExpiresAt: Int
    public let relayURLs: [String]
    public let revision: Int
    public let teamID: String

    public enum CodingKeys: String, CodingKey {
        case devices = "devices"
        case inboundPeers = "inboundPeers"
        case issuedAt = "issuedAt"
        case nextCursor = "nextCursor"
        case permissionExpiresAt = "permissionExpiresAt"
        case relayURLs = "relayURLs"
        case revision = "revision"
        case teamID = "teamId"
    }

    public init(devices: [V2DeviceRecord], inboundPeers: [V2InboundPeerPermission]? = nil, issuedAt: Int, nextCursor: String? = nil, permissionExpiresAt: Int, relayURLs: [String], revision: Int, teamID: String) {
        self.devices = devices
        self.inboundPeers = inboundPeers
        self.issuedAt = issuedAt
        self.nextCursor = nextCursor
        self.permissionExpiresAt = permissionExpiresAt
        self.relayURLs = relayURLs
        self.revision = revision
        self.teamID = teamID
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2DeviceRecord
public struct V2DeviceRecord: Codable, Equatable, Sendable {
    public let descriptor: V2DeviceDescriptor
    public let deviceRecordID: String
    public let revision: Int
    public let revoked: Bool

    public enum CodingKeys: String, CodingKey {
        case descriptor = "descriptor"
        case deviceRecordID = "deviceRecordId"
        case revision = "revision"
        case revoked = "revoked"
    }

    public init(descriptor: V2DeviceDescriptor, deviceRecordID: String, revision: Int, revoked: Bool) {
        self.descriptor = descriptor
        self.deviceRecordID = deviceRecordID
        self.revision = revision
        self.revoked = revoked
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2InboundPeerPermission
public struct V2InboundPeerPermission: Codable, Equatable, Sendable {
    public let device: V2DeviceRecord
    public let permissionExpiresAt: Int

    public enum CodingKeys: String, CodingKey {
        case device = "device"
        case permissionExpiresAt = "permissionExpiresAt"
    }

    public init(device: V2DeviceRecord, permissionExpiresAt: Int) {
        self.device = device
        self.permissionExpiresAt = permissionExpiresAt
    }
}

public enum V2DirectoryResponseSchemaID: String, Codable, Equatable, Sendable {
    case directoryResultV1 = "directory.result.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2ErrorResponse
public struct V2ErrorResponse: Codable, Equatable, Sendable {
    public let code: V2ErrorCode
    public let deliveryReceipt: V2DeliveryReceipt?
    public let requestID: String
    public let retryable: Bool
    public let retryAfterMS: Int?
    public let schemaID: V2ErrorResponseSchemaID

    public enum CodingKeys: String, CodingKey {
        case code = "code"
        case deliveryReceipt = "deliveryReceipt"
        case requestID = "requestId"
        case retryable = "retryable"
        case retryAfterMS = "retryAfterMs"
        case schemaID = "schemaId"
    }

    public init(code: V2ErrorCode, deliveryReceipt: V2DeliveryReceipt? = nil, requestID: String, retryable: Bool, retryAfterMS: Int? = nil, schemaID: V2ErrorResponseSchemaID) {
        self.code = code
        self.deliveryReceipt = deliveryReceipt
        self.requestID = requestID
        self.retryable = retryable
        self.retryAfterMS = retryAfterMS
        self.schemaID = schemaID
    }
}

public enum V2ErrorCode: String, Codable, Equatable, Sendable {
    case challengeExpired = "challenge_expired"
    case challengeInvalid = "challenge_invalid"
    case challengeMissing = "challenge_missing"
    case challengeReplaced = "challenge_replaced"
    case clientUpgradeRequired = "client_upgrade_required"
    case deviceLimit = "device_limit"
    case deviceNotEnrolled = "device_not_enrolled"
    case deviceRevoked = "device_revoked"
    case endpointAlreadyOwned = "endpoint_already_owned"
    case environmentMismatch = "environment_mismatch"
    case identityMismatch = "identity_mismatch"
    case internalError = "internal_error"
    case invalidDeviceProof = "invalid_device_proof"
    case invalidRequest = "invalid_request"
    case keyReplacementRequired = "key_replacement_required"
    case payloadTooLarge = "payload_too_large"
    case permissionDenied = "permission_denied"
    case proofReplayed = "proof_replayed"
    case rateLimited = "rate_limited"
    case resyncRequired = "resync_required"
    case revisionConflict = "revision_conflict"
    case slowConsumer = "slow_consumer"
    case storageLimit = "storage_limit"
    case storageUnavailable = "storage_unavailable"
    case teamAccessRevoked = "team_access_revoked"
    case ticketExpired = "ticket_expired"
    case unauthorized = "unauthorized"
    case unsupportedMediaType = "unsupported_media_type"
    case unsupportedMethod = "unsupported_method"
    case upstreamUnavailable = "upstream_unavailable"
}

public enum V2ErrorResponseSchemaID: String, Codable, Equatable, Sendable {
    case errorV1 = "error.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2ReadyResponse
public struct V2ReadyResponse: Codable, Equatable, Sendable {
    public let challenge: V2Challenge?
    public let deliveryReceipt: V2DeliveryReceipt?
    public let device: V2DeviceRecord?
    public let requestID: String
    public let schemaID: V2ReadyResponseSchemaID
    public let sessionID: String
    public let teamRevision: Int
    public let ticket: V2Ticket?

    public enum CodingKeys: String, CodingKey {
        case challenge = "challenge"
        case deliveryReceipt = "deliveryReceipt"
        case device = "device"
        case requestID = "requestId"
        case schemaID = "schemaId"
        case sessionID = "sessionId"
        case teamRevision = "teamRevision"
        case ticket = "ticket"
    }

    public init(challenge: V2Challenge? = nil, deliveryReceipt: V2DeliveryReceipt? = nil, device: V2DeviceRecord? = nil, requestID: String, schemaID: V2ReadyResponseSchemaID, sessionID: String, teamRevision: Int, ticket: V2Ticket? = nil) {
        self.challenge = challenge
        self.deliveryReceipt = deliveryReceipt
        self.device = device
        self.requestID = requestID
        self.schemaID = schemaID
        self.sessionID = sessionID
        self.teamRevision = teamRevision
        self.ticket = ticket
    }
}

public enum V2ReadyResponseSchemaID: String, Codable, Equatable, Sendable {
    case sessionReadyV1 = "session.ready.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2Ticket
public struct V2Ticket: Codable, Equatable, Sendable {
    public let expiresAt: Int
    public let refreshAfter: Int
    public let token: String

    public enum CodingKeys: String, CodingKey {
        case expiresAt = "expiresAt"
        case refreshAfter = "refreshAfter"
        case token = "token"
    }

    public init(expiresAt: Int, refreshAfter: Int, token: String) {
        self.expiresAt = expiresAt
        self.refreshAfter = refreshAfter
        self.token = token
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2RegisteredResponse
public struct V2RegisteredResponse: Codable, Equatable, Sendable {
    public let deliveryReceipt: V2DeliveryReceipt?
    public let device: V2DeviceRecord
    public let requestID: String
    public let schemaID: V2RegisteredResponseSchemaID

    public enum CodingKeys: String, CodingKey {
        case deliveryReceipt = "deliveryReceipt"
        case device = "device"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(deliveryReceipt: V2DeliveryReceipt? = nil, device: V2DeviceRecord, requestID: String, schemaID: V2RegisteredResponseSchemaID) {
        self.deliveryReceipt = deliveryReceipt
        self.device = device
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

public enum V2RegisteredResponseSchemaID: String, Codable, Equatable, Sendable {
    case deviceRegisteredV1 = "device.registered.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2RelayResponse
public struct V2RelayResponse: Codable, Equatable, Sendable {
    public let credentials: [V2RelayCredential]
    public let deliveryReceipt: V2DeliveryReceipt?
    public let requestID: String
    public let schemaID: V2RelayResponseSchemaID

    public enum CodingKeys: String, CodingKey {
        case credentials = "credentials"
        case deliveryReceipt = "deliveryReceipt"
        case requestID = "requestId"
        case schemaID = "schemaId"
    }

    public init(credentials: [V2RelayCredential], deliveryReceipt: V2DeliveryReceipt? = nil, requestID: String, schemaID: V2RelayResponseSchemaID) {
        self.credentials = credentials
        self.deliveryReceipt = deliveryReceipt
        self.requestID = requestID
        self.schemaID = schemaID
    }
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2RelayCredential
public struct V2RelayCredential: Codable, Equatable, Sendable {
    public let expiresAt: Int
    public let refreshAfter: Int
    public let relayURL: String
    public let token: String

    public enum CodingKeys: String, CodingKey {
        case expiresAt = "expiresAt"
        case refreshAfter = "refreshAfter"
        case relayURL = "relayURL"
        case token = "token"
    }

    public init(expiresAt: Int, refreshAfter: Int, relayURL: String, token: String) {
        self.expiresAt = expiresAt
        self.refreshAfter = refreshAfter
        self.relayURL = relayURL
        self.token = token
    }
}

public enum V2RelayResponseSchemaID: String, Codable, Equatable, Sendable {
    case relayResultV1 = "relay.result.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2RevokedResponse
public struct V2RevokedResponse: Codable, Equatable, Sendable {
    public let deliveryReceipt: V2DeliveryReceipt?
    public let deviceRecordID: String
    public let revision: Int
    public let schemaID: V2RevokedResponseSchemaID
    public let teamID: String

    public enum CodingKeys: String, CodingKey {
        case deliveryReceipt = "deliveryReceipt"
        case deviceRecordID = "deviceRecordId"
        case revision = "revision"
        case schemaID = "schemaId"
        case teamID = "teamId"
    }

    public init(deliveryReceipt: V2DeliveryReceipt? = nil, deviceRecordID: String, revision: Int, schemaID: V2RevokedResponseSchemaID, teamID: String) {
        self.deliveryReceipt = deliveryReceipt
        self.deviceRecordID = deviceRecordID
        self.revision = revision
        self.schemaID = schemaID
        self.teamID = teamID
    }
}

public enum V2RevokedResponseSchemaID: String, Codable, Equatable, Sendable {
    case deviceRevokedV1 = "device.revoked.v1"
}

//
// Hashable or Equatable:
// The compiler will not be able to synthesize the implementation of Hashable or Equatable
// for types that require the use of JSONAny, nor will the implementation of Hashable be
// synthesized for types that have collections (such as arrays or dictionaries).

// MARK: - V2TicketResponse
public struct V2TicketResponse: Codable, Equatable, Sendable {
    public let deliveryReceipt: V2DeliveryReceipt?
    public let requestID: String
    public let schemaID: V2TicketResponseSchemaID
    public let ticket: V2Ticket

    public enum CodingKeys: String, CodingKey {
        case deliveryReceipt = "deliveryReceipt"
        case requestID = "requestId"
        case schemaID = "schemaId"
        case ticket = "ticket"
    }

    public init(deliveryReceipt: V2DeliveryReceipt? = nil, requestID: String, schemaID: V2TicketResponseSchemaID, ticket: V2Ticket) {
        self.deliveryReceipt = deliveryReceipt
        self.requestID = requestID
        self.schemaID = schemaID
        self.ticket = ticket
    }
}

public enum V2TicketResponseSchemaID: String, Codable, Equatable, Sendable {
    case ticketResultV1 = "ticket.result.v1"
}

