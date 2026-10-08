import CmuxLink
import CmuxLinkDirect
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
    public let carriers: [String]
    public let workloads: [BenchWorkload]
    public let bulkRecordBytes: Int

    public init(
        hostID: String,
        address: String,
        port: UInt16,
        hostKey: DirectPublicKey,
        carriers: [CarrierKind] = [.direct],
        workloads: [BenchWorkload] = BenchWorkload.splitSupported,
        bulkRecordBytes: Int = 64 * 1024
    ) {
        self.schema = Self.schema
        self.hostID = hostID
        self.address = address
        self.port = port
        self.hostKey = hostKey.base64
        self.carriers = carriers.map(\.rawValue).sorted()
        self.workloads = workloads.sorted { $0.rawValue < $1.rawValue }
        self.bulkRecordBytes = max(1, bulkRecordBytes)
    }

    /// The peer hints understood by `DirectHintsResolver`.
    public var peer: LinkPeer {
        LinkPeer(hostID: hostID, hints: [
            "direct.address": address,
            "direct.port": String(port),
            "direct.hostKey": hostKey,
        ])
    }

    public var directEndpoint: DirectEndpoint? {
        DirectHintsResolver().endpoint(from: peer.hints)
    }

    public func validate() throws {
        guard schema == Self.schema else { throw BenchSplitError.invalidDescriptor("schema") }
        guard !hostID.isEmpty, DirectAddress(address) != nil, port != 0 else {
            throw BenchSplitError.invalidDescriptor("host endpoint")
        }
        guard DirectPublicKey(base64: hostKey) != nil else {
            throw BenchSplitError.invalidDescriptor("host key")
        }
        guard carriers.contains(CarrierKind.direct.rawValue) else {
            throw BenchSplitError.invalidDescriptor("direct carrier missing")
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
