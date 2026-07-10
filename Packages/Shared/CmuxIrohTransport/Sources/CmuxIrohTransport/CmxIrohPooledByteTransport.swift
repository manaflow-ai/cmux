import CMUXMobileCore
import Foundation

/// Projects a pooled admitted session's control lane through the legacy byte seam.
actor CmxIrohPooledByteTransport: CmxByteTransport {
    private let request: CmxByteTransportRequest
    private let pool: CmxIrohClientSessionPool
    private var session: CmxIrohClientSession?
    private var closed = false

    init(request: CmxByteTransportRequest, pool: CmxIrohClientSessionPool) {
        self.request = request
        self.pool = pool
    }

    func connect() async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if session != nil { return }
        session = try await pool.session(for: request)
    }

    func receive() async throws -> Data? {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        do {
            return try await session.receiveControl()
        } catch {
            await pool.invalidate(for: request)
            self.session = nil
            throw error
        }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        do {
            try await session.sendControl(data)
        } catch {
            await pool.invalidate(for: request)
            self.session = nil
            throw error
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        session = nil
    }
}
