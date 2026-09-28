import Foundation
import IrohLib

// These two adapters share a file deliberately: they are a closed pair of
// fixture-thin wrappers over IrohLib's stream halves, minted only by
// `IrohCarrierConnection`, and neither is meaningful without the other.

/// Forwards the carrier send-stream surface onto Iroh's `SendStream`.
struct IrohCarrierSendStream: IrxCarrierSendStream {
    let stream: SendStream

    func writeAll(_ data: Data) async throws { try await stream.writeAll(buf: data) }
    func finish() async throws { try await stream.finish() }
    func reset(errorCode: UInt64) async throws { try await stream.reset(errorCode: errorCode) }
    func setPriority(_ priority: Int32) async throws { try await stream.setPriority(p: priority) }
}

/// Forwards the carrier receive-stream surface onto Iroh's `RecvStream`.
struct IrohCarrierRecvStream: IrxCarrierRecvStream {
    let stream: RecvStream

    func read(sizeLimit: UInt32) async throws -> Data { try await stream.read(sizeLimit: sizeLimit) }
    func stop(errorCode: UInt64) async throws { try await stream.stop(errorCode: errorCode) }
}
