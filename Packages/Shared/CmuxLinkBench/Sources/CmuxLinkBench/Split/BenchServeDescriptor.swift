import CmuxLink
import CmuxLinkDirect
import CmuxLinkWebRTC
import CmuxLinkWG
import Foundation

/// A short-lived descriptor printed by `cmux-link-bench serve` and consumed by
/// the DEV Link bench screen. It contains the pinned host key and address;
/// neither is learned from an unauthenticated socket.
public struct BenchServeDescriptor: Codable, Hashable, Sendable {
    public static let schema = "cmux-link-bench-serve/1"

    public let schema: String
    public let hostID: String
    public let address: String
    public let port: UInt16
    public let hostKey: String
    /// Pinned P-256 key used by the V1 WebRTC carrier. It is optional so a
    /// direct-only descriptor remains byte-for-byte compatible with the first
    /// split descriptor format.
    public let webrtcHostKey: String?
    /// Pinned X25519 key used by the V2 WireGuard-over-WebRTC carrier.
    public let wireGuardHostKey: String?
    /// Host install id used as the signaling `to` endpoint. The host id is
    /// the default when this is absent, matching B2's signal routing rule.
    public let signalTarget: String?
    public let carriers: [String]
    public let workloads: [BenchWorkload]
    public let bulkRecordBytes: Int

    public init(
        hostID: String,
        address: String,
        port: UInt16,
        hostKey: DirectPublicKey,
        webrtcHostKey: String? = nil,
        wireGuardHostKey: String? = nil,
        signalTarget: String? = nil,
        carriers: [CarrierKind] = [.direct],
        workloads: [BenchWorkload] = BenchWorkload.splitSupported,
        bulkRecordBytes: Int = 64 * 1024
    ) {
        self.schema = Self.schema
        self.hostID = hostID
        self.address = address
        self.port = port
        self.hostKey = hostKey.base64
        self.webrtcHostKey = webrtcHostKey
        self.wireGuardHostKey = wireGuardHostKey
        self.signalTarget = signalTarget
        self.carriers = carriers.map(\.rawValue).sorted()
        self.workloads = workloads.sorted { $0.rawValue < $1.rawValue }
        self.bulkRecordBytes = max(1, bulkRecordBytes)
    }

    /// Carrier-specific peer hints understood by the selected split adapter.
    public var peer: LinkPeer {
        var hints = ["direct.hostKey": hostKey]
        if !address.isEmpty, port != 0 {
            hints["direct.address"] = address
            hints["direct.port"] = String(port)
        }
        if let webrtcHostKey { hints["webrtc.hostKey"] = webrtcHostKey }
        if let wireGuardHostKey { hints["wg.hostKey"] = wireGuardHostKey }
        if let signalTarget { hints["webrtc.to"] = signalTarget }
        return LinkPeer(hostID: hostID, hints: hints)
    }

    public var directEndpoint: DirectEndpoint? {
        DirectHintsResolver().endpoint(from: peer.hints)
    }

    public func validate() throws {
        guard schema == Self.schema else { throw BenchSplitError.invalidDescriptor("schema") }
        guard !hostID.isEmpty else {
            throw BenchSplitError.invalidDescriptor("host endpoint")
        }
        guard DirectPublicKey(base64: hostKey) != nil else {
            throw BenchSplitError.invalidDescriptor("host key")
        }
        let carrierKinds = Set(carriers)
        guard !carrierKinds.isEmpty else { throw BenchSplitError.invalidDescriptor("carriers") }
        guard carrierKinds.allSatisfy({
            $0 == CarrierKind.direct.rawValue ||
                $0 == CarrierKind.webrtc.rawValue ||
                $0 == CarrierKind.webrtcWireGuard.rawValue
        }) else {
            throw BenchSplitError.invalidDescriptor("carrier")
        }
        if carrierKinds.contains(CarrierKind.direct.rawValue),
           (DirectAddress(address) == nil || port == 0) {
            throw BenchSplitError.invalidDescriptor("direct endpoint")
        }
        if carrierKinds.contains(CarrierKind.webrtc.rawValue) {
            guard let webrtcHostKey, WebRTCPublicKey(base64: webrtcHostKey) != nil else {
                throw BenchSplitError.invalidDescriptor("webrtc host key")
            }
        }
        if carrierKinds.contains(CarrierKind.webrtcWireGuard.rawValue) {
            guard let wireGuardHostKey, WireGuardPublicKey(base64: wireGuardHostKey) != nil else {
                throw BenchSplitError.invalidDescriptor("wireguard host key")
            }
        }
        guard !workloads.isEmpty, workloads.allSatisfy({ BenchWorkload.splitSupported.contains($0) }) else {
            throw BenchSplitError.invalidDescriptor("workloads")
        }
        guard (1...(256 * 1024 - LinkFrame.dataOverhead)).contains(bulkRecordBytes) else {
            throw BenchSplitError.invalidDescriptor("bulk record size")
        }
    }

    public static func decode(_ data: Data) throws -> BenchServeDescriptor {
        let descriptor = try JSONDecoder().decode(Self.self, from: data)
        try descriptor.validate()
        return descriptor
    }
}

public extension BenchWorkload {
    /// Workloads that can run while the Mac owns the peer channel service.
    /// Raw transport and fault injection remain process-local until the split
    /// control protocol grows explicit fault operations.
    static let splitSupported: [BenchWorkload] = [
        .coldConnect, .rttIdle, .rttUnderBulk, .terminalFlood, .bulkFile,
    ]
}

public enum BenchSplitError: Error, LocalizedError, Sendable, Hashable {
    case invalidDescriptor(String)
    case unsupportedWorkload(BenchWorkload)
    case unauthorized(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidDescriptor(field): "invalid benchmark descriptor: \(field)"
        case let .unsupportedWorkload(workload): "split benchmark does not support \(workload.rawValue)"
        case let .unauthorized(message): "benchmark authorization failed: \(message)"
        case let .server(message): "benchmark server failed: \(message)"
        }
    }
}
