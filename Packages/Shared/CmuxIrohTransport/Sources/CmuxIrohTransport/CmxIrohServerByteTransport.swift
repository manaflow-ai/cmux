public import CMUXMobileCore
public import Foundation

/// Presents one already-admitted Iroh control stream through the shared RPC byte seam.
public actor CmxIrohServerByteTransport: CmxByteTransport {
    private let session: CmxIrohServerSession
    private let epoch: UInt64
    private var connected = false
    private var closed = false

    public init(session: CmxIrohServerSession, epoch: UInt64 = 1) {
        self.session = session
        self.epoch = epoch
    }

    public func connect() async throws {
        guard !closed else { throw CmxIrohServerSessionError.alreadyClosed }
        _ = try await session.admittedPeerContext()
        connected = true
    }

    public func receive() async throws -> Data? {
        try requireConnected()
        return try await session.receiveControl(epoch: epoch)
    }

    public func send(_ data: Data) async throws {
        try requireConnected()
        try await session.sendControl(data, epoch: epoch)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        connected = false
        await session.releaseControl(epoch: epoch)
    }

    private func requireConnected() throws {
        guard !closed else { throw CmxIrohServerSessionError.alreadyClosed }
        guard connected else { throw CmxIrohServerSessionError.notAdmitted }
    }
}
