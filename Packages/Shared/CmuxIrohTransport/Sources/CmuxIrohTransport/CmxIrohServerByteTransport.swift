public import CMUXMobileCore
public import Foundation

/// Presents one already-admitted Iroh control stream through the shared RPC byte seam.
public actor CmxIrohServerByteTransport: CmxByteTransport {
    private let session: CmxIrohServerSession
    private var connected = false
    private var closed = false

    public init(session: CmxIrohServerSession) {
        self.session = session
    }

    public func connect() async throws {
        guard !closed else { throw CmxIrohServerSessionError.alreadyClosed }
        _ = try await session.admittedPeerContext()
        connected = true
    }

    public func receive() async throws -> Data? {
        try requireConnected()
        return try await session.receiveControl()
    }

    public func send(_ data: Data) async throws {
        try requireConnected()
        try await session.sendControl(data)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        connected = false
        await session.close()
    }

    private func requireConnected() throws {
        guard !closed else { throw CmxIrohServerSessionError.alreadyClosed }
        guard connected else { throw CmxIrohServerSessionError.notAdmitted }
    }
}
