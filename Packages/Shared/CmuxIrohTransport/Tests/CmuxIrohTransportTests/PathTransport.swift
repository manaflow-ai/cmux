import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

/// Minimal path-observing byte transport used by deferred-observer tests.
actor PathTransport: CmxByteTransport, CmxByteTransportPathObserving {
    private let paths: AsyncStream<CmxTransportPath>
    private let pathContinuation: AsyncStream<CmxTransportPath>.Continuation
    private var connected = false
    private var closed = false

    init() {
        let stream = AsyncStream<CmxTransportPath>.makeStream()
        paths = stream.stream
        pathContinuation = stream.continuation
        pathContinuation.yield(.irohDirect)
    }

    func connect() {
        connected = true
    }

    func receive() throws -> Data? {
        guard connected, !closed else {
            throw CmxIrohByteTransportError.notConnected
        }
        return nil
    }

    func send(_: Data) throws {
        guard connected, !closed else {
            throw CmxIrohByteTransportError.notConnected
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        pathContinuation.finish()
    }

    func currentTransportPath() -> CmxTransportPath {
        .irohDirect
    }

    func transportPathChanges() -> AsyncStream<CmxTransportPath> {
        paths
    }
}
