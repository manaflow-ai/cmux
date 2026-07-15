import CMUXMobileCore
import Foundation

/// Projects a pooled admitted session's control lane through the legacy byte seam.
actor CmxIrohPooledByteTransport: CmxByteTransport {
    private let request: CmxByteTransportRequest
    private let pool: CmxIrohClientSessionPool
    private let ownerID = UUID()
    private var session: CmxIrohClientSession?
    private var ownsControlSession = false
    private var closed = false

    init(request: CmxByteTransportRequest, pool: CmxIrohClientSessionPool) {
        self.request = request
        self.pool = pool
    }

    func connect() async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if session != nil { return }
        let acquired = try await pool.acquireControlSession(
            for: request,
            ownerID: ownerID
        )
        guard !closed else {
            await pool.releaseControlSession(for: request, ownerID: ownerID)
            throw CmxIrohByteTransportError.alreadyClosed
        }
        ownsControlSession = true
        session = acquired
    }

    func receive() async throws -> Data? {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        do {
            return try await session.receiveControl()
        } catch {
            await releaseOwnedControlSession()
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
            await releaseOwnedControlSession()
            self.session = nil
            throw error
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        session = nil
        // The mobile RPC session owns control framing and may leave a cancelled
        // read or partial frame behind. Never hand that stream to a replacement
        // RPC owner; close the peer session so the next control transport redials.
        await releaseOwnedControlSession()
    }

    private func releaseOwnedControlSession() async {
        guard ownsControlSession else { return }
        ownsControlSession = false
        await pool.releaseControlSession(for: request, ownerID: ownerID)
    }
}
