import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSettings
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os


// MARK: - Connection Accept & Tracking
extension MobileHostService {
    nonisolated static func acceptConnectionOffMain(
        _ connection: NWConnection,
        generation: UUID
    ) {
        Task.detached(priority: .userInitiated) {
            let canAccept = await MobileHostService.shared.canAcceptConnection(generation: generation)
            guard canAccept else {
                mobileHostLog.info("mobile host rejected stale listener connection")
                connection.cancel()
                MobileHostRequestActivity.endConnection()
                return
            }

            #if !DEBUG
            // Release builds never advertise a loopback route (the 127.0.0.1
            // `debugLoopback` route is DEBUG-only, see `MobileRouteResolver`), so a
            // legitimate phone always reaches the Mac over the Tailscale interface.
            // A connection arriving on loopback in release can only be a local
            // process (or a browser that somehow framed the binary protocol), never
            // the real client, so refuse it outright. DEBUG keeps loopback so the
            // iOS Simulator (which reaches the Mac via 127.0.0.1) can still pair.
            if Self.isLoopbackConnection(connection) {
                mobileHostLog.error("mobile host rejected loopback connection in release build")
                connection.cancel()
                MobileHostRequestActivity.endConnection()
                return
            }
            #endif

            let id = UUID()
            let session = MobileHostConnection(
                id: id,
                connection: connection,
                authorizeRequest: { request in
                    if !Self.requiresAuthorization(method: request.method) {
                        return nil
                    }
                    return await MobileHostService.shared.authorizationError(for: request)
                },
                onAuthorizedRequest: { request in
                    guard let clientID = Self.clientID(from: request.params) else {
                        return
                    }
                    await MobileHostService.shared.recordClientID(clientID, for: id)
                },
                handleRequest: { request in
                    if request.method == "mobile.host.status" {
                        return MobileHostPublicStatusCache.result()
                    }
                    let result = await TerminalController.shared.mobileHostHandleRPC(request)
                    await MobileHostService.shared.recordCreatedResourcesIfNeeded(
                        request: request,
                        result: result
                    )
                    return result
                },
                onClose: { id in
                    MobileHostConnectionRegistry.shared.remove(id: id)
                    await MobileHostService.shared.removeConnection(id: id)
                }
            )
            guard MobileHostConnectionRegistry.shared.insert(
                session,
                id: id,
                limit: Self.maximumActiveConnectionCount
            ) else {
                mobileHostLog.error("mobile host rejected connection because active connection limit was reached")
                connection.cancel()
                MobileHostRequestActivity.endConnection()
                return
            }
            await session.start()
        }
    }

    private func canAcceptConnection(generation: UUID) -> Bool {
        listener != nil && generation == listenerGeneration
    }

    /// Whether an incoming connection's remote peer is on the loopback interface.
    ///
    /// Used to refuse local connections in release builds, where no legitimate
    /// client ever connects via `127.0.0.1`/`::1`.
    private nonisolated static func isLoopbackConnection(_ connection: NWConnection) -> Bool {
        isLoopbackEndpoint(connection.endpoint) || isLoopbackEndpoint(connection.currentPath?.remoteEndpoint)
    }

    private nonisolated static func isLoopbackEndpoint(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _)? = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            // 127.0.0.0/8
            return address.rawValue.first == 127
        case let .ipv6(address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return false }
            // ::1
            let isV6Loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            // IPv4-mapped loopback ::ffff:127.0.0.0/8
            let isV4MappedLoopback = bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
            return isV6Loopback || isV4MappedLoopback
        case let .name(name, _):
            let lowered = name.lowercased()
            return lowered == "localhost" || lowered.hasSuffix(".localhost")
        @unknown default:
            return false
        }
    }

    func removeConnection(id: UUID) {
        MobileHostConnectionRegistry.shared.remove(id: id)
        activeConnections.removeValue(forKey: id)
        // Drop this connection's sticky viewport reports so a disconnected
        // device stops pinning the shared grid (and its macOS viewport border
        // clears) even though it never sent an explicit clear.
        let clientIDs = clientIDsByConnectionID[id] ?? []
        clientIDsByConnectionID.removeValue(forKey: id)
        if !clientIDs.isEmpty {
            TerminalController.shared.clearMobileViewportReports(
                clientIDs: clientIDs,
                reason: "mobile.connection.closed"
            )
        }
        MobileHostRequestActivity.endConnection()
    }

    func recordClientID(_ clientID: String, for connectionID: UUID) {
        var clientIDs = clientIDsByConnectionID[connectionID] ?? []
        clientIDs.insert(clientID)
        clientIDsByConnectionID[connectionID] = clientIDs
    }

    private nonisolated static func clientID(from params: [String: Any]) -> String? {
        let trimmed = (params["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

}
