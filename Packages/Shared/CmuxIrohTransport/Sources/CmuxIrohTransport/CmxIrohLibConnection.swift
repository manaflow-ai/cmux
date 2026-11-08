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
    let closeAttributionStore = CmxIrohConnectionCloseAttributionStore()

    init(driver: Connection) throws {
        self.driver = driver
        peerIdentity = try CmxIrohLibIdentity.peerIdentity(driver.remoteId())
    }

    @concurrent
    func remoteIdentity() async -> CmxIrohPeerIdentity {
        peerIdentity
    }

    @concurrent
    func connectionContinuityID() async -> UInt64 {
        driver.stableId()
    }

    @concurrent
    func observedSelectedPath() async -> CmxIrohObservedConnectionPath {
        CmxIrohObservedConnectionPath(
            snapshots: driver.paths().map(CmxIrohConnectionPathSnapshot.init)
        )
    }

    @concurrent
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

    @concurrent
    func observedPathEvents() async -> AsyncStream<CmxIrohConnectionPathEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let callback = CmxIrohLibPathEventCallback(continuation: continuation)
            let handle = driver.watchPathEvents(callback: callback)
            let closeTask = Task {
                let cause = await driver.closed()
                _ = await closeAttributionStore.recordAuthoritative(cause: cause)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                closeTask.cancel()
                Task { await handle.stop() }
            }
        }
    }

    @concurrent
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

    @concurrent
    func authorizeNatTraversal() async throws {
        try await driver.authorizeNatTraversal()
    }

    @concurrent
    func openBidirectionalStream() async throws -> CmxIrohBidirectionalStream {
        Self.stream(try await driver.openBi())
    }

    @concurrent
    func acceptBidirectionalStream() async throws -> CmxIrohBidirectionalStream {
        Self.stream(try await driver.acceptBi())
    }

    @concurrent
    func openSendStream() async throws -> any CmxIrohSendStream {
        CmxIrohLibSendStream(driver: try await driver.openUni())
    }

    @concurrent
    func acceptReceiveStream() async throws -> any CmxIrohReceiveStream {
        CmxIrohLibReceiveStream(driver: try await driver.acceptUni())
    }

    @concurrent
    func waitUntilClosed() async {
        let cause = await driver.closed()
        _ = await closeAttributionStore.recordAuthoritative(cause: cause)
    }

    @concurrent
    func closeAttribution() async -> CmxIrohConnectionCloseAttribution {
        if let cause = driver.closeReason() {
            return await closeAttributionStore.recordAuthoritative(cause: cause)
        }
        if let attribution = await closeAttributionStore.current() {
            return attribution
        }
        return CmxIrohConnectionCloseAttribution(
            initiator: .unknown,
            applicationErrorCode: nil,
            failureKind: .unknown
        )
    }

    @concurrent
    func isClosed() async -> Bool {
        guard let cause = driver.closeReason() else { return false }
        _ = await closeAttributionStore.recordAuthoritative(cause: cause)
        return true
    }

    @concurrent
    func close(errorCode: UInt64, reason: String) async {
        let code = Int64(exactly: errorCode) ?? Int64.max
        let parsedReason = CmxIrohConnectionCloseAttribution.classify(
            "closed by peer: \(reason) (code \(code))"
        )
        await closeAttributionStore.recordTentative(CmxIrohConnectionCloseAttribution(
            initiator: .local,
            applicationErrorCode: code,
            failureKind: parsedReason.failureKind == .unknown
                ? .cancelled
                : parsedReason.failureKind,
            remoteReason: parsedReason.remoteReason
        ))
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
