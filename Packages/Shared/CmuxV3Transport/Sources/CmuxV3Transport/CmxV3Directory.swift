import Foundation

public struct CmxV3Directory: Decodable, Sendable {
    public let team: String
    public let revision: Int64
    public let devices: [CmxV3DirectoryDevice]
    public init(team: String, revision: Int64, devices: [CmxV3DirectoryDevice]) { self.team = team; self.revision = revision; self.devices = devices }
}

public struct CmxV3DirectoryDevice: Decodable, Sendable {
    public let peerID: String
    public let deviceID: String
    public let addresses: [String]
    public let active: Bool
    public let tags: [String]
    public let lease: CmxV3DirectoryLease
    public let metadata: CmxV3DeviceMetadata?
    enum CodingKeys: String, CodingKey { case peerID = "peer_id"; case deviceID = "device_id"; case addresses; case active; case tags; case lease; case metadata }
    public init(peerID: String, deviceID: String, addresses: [String], active: Bool, tags: [String], lease: CmxV3DirectoryLease, metadata: CmxV3DeviceMetadata? = nil) { self.peerID = peerID; self.deviceID = deviceID; self.addresses = addresses; self.active = active; self.tags = tags; self.lease = lease; self.metadata = metadata }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        peerID = try container.decode(String.self, forKey: .peerID)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        lease = try container.decodeIfPresent(CmxV3DirectoryLease.self, forKey: .lease) ?? CmxV3DirectoryLease(renewEverySeconds: 30)
        metadata = try container.decodeIfPresent(CmxV3DeviceMetadata.self, forKey: .metadata)
    }
}

public struct CmxV3DirectoryLease: Decodable, Sendable {
    public let renewEverySeconds: UInt32
    public init(renewEverySeconds: UInt32) { self.renewEverySeconds = renewEverySeconds }
    enum CodingKeys: String, CodingKey { case renewEverySeconds = "renew_every_seconds" }
}
