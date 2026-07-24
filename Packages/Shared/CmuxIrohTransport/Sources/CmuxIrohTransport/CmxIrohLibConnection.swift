import CMUXMobileCore
import Foundation
import IrohLib

struct CmxIrohLibConnection:
    CmxIrohConnection,
    CmxIrohConnectionContinuityIdentifying,
    CmxIrohConnectionPathInspecting
{
    let driver: Connection
    let peerIdentity: CmxIrohPeerIdentity

    init(driver: Connection) throws {
        self.driver = driver
        peerIdentity = try CmxIrohLibIdentity.peerIdentity(driver.remoteId())
    }

    func remoteIdentity() async -> CmxIrohPeerIdentity {
        peerIdentity
    }

    func connectionContinuityID() async -> UInt64 {
        driver.stableId()
    }

    func observedSelectedPath() async -> CmxIrohObservedConnectionPath {
        CmxIrohObservedConnectionPath(
            snapshots: driver.paths().map(CmxIrohConnectionPathSnapshot.init)
        )
    }

    func observedSelectedPathChanges() async -> AsyncStream<CmxIrohObservedConnectionPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let callback = CmxIrohLibPathChangeCallback(continuation: continuation)
            let handle = driver.watchPaths(callback: callback)
            continuation.yield(
                CmxIrohObservedConnectionPath(
                    snapshots: driver.paths().map(CmxIrohConnectionPathSnapshot.init)
                )
            )
            continuation.onTermination = { @Sendable _ in
                Task { await handle.stop() }
            }
        }
    }

    func setIncomingStreamLimits(
        maximumBidirectionalStreamCount: UInt64,
        maximumUnidirectionalStreamCount: UInt64
    ) async throws {
        try driver.setMaxConcurrentBiStreams(
            count: maximumBidirectionalStreamCount
        )
        try driver.setMaxConcurrentUniStreams(
            count: maximumUnidirectionalStreamCount
        )
    }

    func authorizeNatTraversal() async throws {
        try await driver.authorizeNatTraversal()
    }

    func openBidirectionalStream() async throws -> CmxIrohBidirectionalStream {
        Self.stream(try await driver.openBi())
    }

    func acceptBidirectionalStream() async throws -> CmxIrohBidirectionalStream {
        Self.stream(try await driver.acceptBi())
    }

    func openSendStream() async throws -> any CmxIrohSendStream {
        CmxIrohLibSendStream(driver: try await driver.openUni())
    }

    func acceptReceiveStream() async throws -> any CmxIrohReceiveStream {
        CmxIrohLibReceiveStream(driver: try await driver.acceptUni())
    }

    func waitUntilClosed() async {
        _ = await driver.closed()
    }

    func isClosed() async -> Bool {
        driver.closeReason() != nil
    }

    func close(errorCode: UInt64, reason: String) async {
        let code = Int64(exactly: errorCode) ?? Int64.max
        try? driver.close(
            errorCode: code,
            reason: Data(reason.utf8.prefix(1_024))
        )
    }

    private static func stream(_ stream: BiStream) -> CmxIrohBidirectionalStream {
        CmxIrohBidirectionalStream(
            receiveStream: CmxIrohLibReceiveStream(driver: stream.recv()),
            sendStream: CmxIrohLibSendStream(driver: stream.send())
        )
    }
}

enum CmxIrohLibIdentity {
    static func peerIdentity(_ value: EndpointId) throws -> CmxIrohPeerIdentity {
        let bytes = value.toBytes()
        guard bytes.count == 32 else { throw CmxIrohLibError.invalidEndpointIdentity }
        return try CmxIrohPeerIdentity(endpointID: bytes.hex)
    }

    static func endpointID(_ value: CmxIrohPeerIdentity) throws -> EndpointId {
        guard let bytes = Data(canonicalHex: value.endpointID), bytes.count == 32 else {
            throw CmxIrohLibError.invalidEndpointIdentity
        }
        return try EndpointId.fromBytes(bytes: bytes)
    }
}

private extension Data {
    init?(canonicalHex value: String) {
        guard value.utf8.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: value.utf8.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
