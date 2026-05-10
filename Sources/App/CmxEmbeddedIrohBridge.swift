import Foundation

final class CmxEmbeddedIrohBridge: @unchecked Sendable {
    private static let ticketBufferSize = 64 * 1024
    private static let errorBufferSize = 4096

    let ticket: String
    private let stateLock = NSLock()
    private var handle: OpaquePointer?

    private init(handle: OpaquePointer, ticket: String) {
        self.handle = handle
        self.ticket = ticket
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        stateLock.lock()
        let running = handle != nil
        stateLock.unlock()
        return running
    }

    func stop() {
        stateLock.lock()
        let handleToStop = handle
        handle = nil
        stateLock.unlock()
        guard let handleToStop else { return }
        Self.stopHandleOffMain(handleToStop)
    }

    func retire() {
        stateLock.lock()
        let handleToRetire = handle
        handle = nil
        stateLock.unlock()
        guard let handleToRetire else { return }
        cmux_iroh_host_retire(handleToRetire)
    }

    static func start(context: CmxHiveBridgeStartContext) async throws -> CmxEmbeddedIrohBridge {
        try await Task.detached(priority: .utility) {
            let config = try Self.hostConfigJSON(context: context)
            var ticketBuffer = [CChar](repeating: 0, count: Self.ticketBufferSize)
            var errorBuffer = [CChar](repeating: 0, count: Self.errorBufferSize)
            let handle: OpaquePointer? = ticketBuffer.withUnsafeMutableBufferPointer { ticketOut in
                errorBuffer.withUnsafeMutableBufferPointer { errorOut in
                    guard let ticketBase = ticketOut.baseAddress,
                          let errorBase = errorOut.baseAddress else {
                        return nil
                    }
                    return config.withCString { configPointer in
                        cmux_iroh_host_start(
                            configPointer,
                            ticketBase,
                            ticketOut.count,
                            errorBase,
                            errorOut.count
                        )
                    }
                }
            }
            guard let handle else {
                let message = String(cString: errorBuffer)
                throw CmxHiveWorkspacePublisherError.embeddedBridgeStartFailed(
                    message.isEmpty ? "unknown error" : message
                )
            }
            let ticket = String(cString: ticketBuffer)
            guard !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                cmux_iroh_host_stop(handle)
                throw CmxHiveWorkspacePublisherError.bridgeTicketMissing
            }
            return CmxEmbeddedIrohBridge(handle: handle, ticket: ticket)
        }.value
    }

    private static func stopHandleOffMain(_ handle: OpaquePointer) {
        let handleAddress = UInt(bitPattern: handle)
        Task.detached(priority: .utility) {
            guard let rawPointer = UnsafeMutableRawPointer(bitPattern: handleAddress) else { return }
            cmux_iroh_host_stop(OpaquePointer(rawPointer))
        }
    }

    private static func hostConfigJSON(context: CmxHiveBridgeStartContext) throws -> String {
        let config: [String: Any] = [
            "socket_path": context.socketPath,
            "relay_mode": UInt32(0),
            "pairing": [
                "pairing_id": context.pairingID,
                "secret": context.pairingSecret,
                "rivet_endpoint": context.rivetEndpoint,
                "stack_project_id": context.stackProjectID,
                "expires_at_unix": context.expiresAtUnix,
            ],
            "node": [
                "id": context.nodeID,
                "name": context.nodeName,
                "subtitle": context.nodeSubtitle,
                "kind": context.nodeKind,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CmxHiveWorkspacePublisherError.embeddedBridgeStartFailed("host config is not UTF-8")
        }
        return json
    }
}
