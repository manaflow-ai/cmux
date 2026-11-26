#if canImport(IrohLib)
import Foundation
import IrohLib

/// ``IrxQUICConnection`` over an iroh connection.
struct IrxIrohLibQUICConnection: IrxQUICConnection {
    let native: Connection

    func remoteEndpointID() -> Data { native.remoteId().toBytes() }
    func stableID() -> UInt64 { native.stableId() }

    func paths() -> [IrxQUICPath] {
        native.paths().map {
            IrxQUICPath(isSelected: $0.isSelected, isRelay: $0.isRelay, remoteAddress: "\($0.remoteAddr)")
        }
    }

    func closeReason() -> String? { native.closeReason() }
    func closed() async -> String { await native.closed() }
    func setMaxConcurrentBiStreams(_ count: UInt64) throws { try native.setMaxConcurrentBiStreams(count: count) }
    func setMaxConcurrentUniStreams(_ count: UInt64) throws { try native.setMaxConcurrentUniStreams(count: count) }

    func openBi() async throws -> IrxQUICBiStream {
        let stream = try await native.openBi()
        return IrxQUICBiStream(send: IrxIrohLibSendStream(native: stream.send()), recv: IrxIrohLibRecvStream(native: stream.recv()))
    }

    func openUni() async throws -> any IrxQUICSendStream {
        IrxIrohLibSendStream(native: try await native.openUni())
    }

    func acceptBi() async throws -> IrxQUICBiStream {
        let stream = try await native.acceptBi()
        return IrxQUICBiStream(send: IrxIrohLibSendStream(native: stream.send()), recv: IrxIrohLibRecvStream(native: stream.recv()))
    }

    func acceptUni() async throws -> any IrxQUICRecvStream {
        IrxIrohLibRecvStream(native: try await native.acceptUni())
    }

    func authorizeNatTraversal() async throws { try await native.authorizeNatTraversal() }
    func close(errorCode: Int64, reason: Data) throws { try native.close(errorCode: errorCode, reason: reason) }
}

struct IrxIrohLibSendStream: IrxQUICSendStream {
    let native: SendStream

    func writeAll(_ data: Data) async throws { try await native.writeAll(buf: data) }
    func setPriority(_ priority: Int32) async throws { try await native.setPriority(p: priority) }
    func finish() async throws { try await native.finish() }
    func reset(errorCode: UInt64) async throws { try await native.reset(errorCode: errorCode) }
}

struct IrxIrohLibRecvStream: IrxQUICRecvStream {
    let native: RecvStream

    func read(sizeLimit: UInt32) async throws -> Data { try await native.read(sizeLimit: sizeLimit) }
    func stop(errorCode: UInt64) async throws { try await native.stop(errorCode: errorCode) }
}
#endif
