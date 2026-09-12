import IrohLib

extension IrohSubstrate {
    /// Converts the native handshake result into the peer that owns its streams.
    func startPeer(
        role: IrohPeerConnection.Role,
        connect: @Sendable () async throws -> Connection
    ) async throws -> IrohPeerConnection {
        let connection = try await connect()
        let peer = IrohPeerConnection(connection: connection, role: role)
        do {
            // Native success transfers ownership here even when cancellation
            // won concurrently. The attempt token cannot close a live result.
            try Task.checkCancellation()
            await peer.start()
            try Task.checkCancellation()
            return peer
        } catch {
            await peer.closeAll()
            throw error
        }
    }
}
