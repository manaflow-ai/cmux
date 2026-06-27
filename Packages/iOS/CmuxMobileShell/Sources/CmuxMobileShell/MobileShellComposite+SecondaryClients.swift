import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import os

nonisolated private let secondaryClientLog = Logger(
    subsystem: "com.cmux.mobile",
    category: "MobileShellComposite"
)

extension MobileShellComposite {
    /// Build a persistent read-only client to one other Mac. The caller owns disconnecting it.
    func makeSecondaryClient(
        for mac: MobilePairedMac,
        allowDurableTicket: Bool = true
    ) async -> SecondaryClientHandle? {
        guard let runtime else { return nil }
        let supportedKinds = runtime.supportedRouteKinds
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            mac.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        ) else {
            return nil
        }
        let ticket: CmxAttachTicket
        let usedDurableTicket: Bool
        if allowDurableTicket, let durableTicket = durableAttachTicket(for: mac) {
            ticket = durableTicket
            usedDurableTicket = true
        } else {
            do {
                ticket = try await manualHostTicket(
                    name: mac.displayName ?? host,
                    host: host,
                    port: port,
                    attemptStartedAt: nil
                )
            } catch {
                secondaryClientLog.warning(
                    "secondary client: ticket failed mac=\(mac.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
                )
                return nil
            }
            usedDurableTicket = false
        }
        let supportedRoutes = supportedRoutes(for: ticket, supportedKinds: supportedKinds)
        let route = supportedRoutes.first(where: { route in
            if case let .hostPort(routeHost, routePort) = route.endpoint {
                return routeHost == host && routePort == port
            }
            return false
        }) ?? supportedRoutes.first(where: { $0.kind != .debugLoopback })
            ?? supportedRoutes.first
        guard let route else { return nil }
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
            connectAttemptRegistry: connectAttemptRegistry,
            stackTokenGate: stackTokenGate,
            stackTokenForceRefreshGate: stackTokenForceRefreshGate
        )
        let capabilities = await fetchSecondaryHostCapabilities(on: client)
        return SecondaryClientHandle(
            client: client,
            route: route,
            ticket: ticket,
            usedDurableTicket: usedDurableTicket,
            supportedHostCapabilities: capabilities,
            actionCapabilities: Self.workspaceActionCapabilities(from: capabilities)
        )
    }

    func fetchSecondaryHostCapabilities(on client: MobileCoreRPCClient) async -> Set<String> {
        guard let runtime else { return [] }
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            guard let payload = try? MobileHostStatusResponse.decode(data) else { return [] }
            return Set(payload.capabilities)
        } catch {
            secondaryClientLog.warning("secondary host status failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// Fetch one Mac's workspace list over an existing client.
    func fetchSecondaryWorkspaces(
        on client: MobileCoreRPCClient,
        macDeviceID: String
    ) async -> [MobileWorkspacePreview]? {
        do {
            return try await fetchSecondaryWorkspacesThrowing(on: client, macDeviceID: macDeviceID)
        } catch {
            secondaryClientLog.warning(
                "secondary workspace fetch failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            return nil
        }
    }

    func fetchSecondaryWorkspacesThrowing(
        on client: MobileCoreRPCClient,
        macDeviceID: String
    ) async throws -> [MobileWorkspacePreview] {
        guard let runtime else { throw MobileShellConnectionError.connectionClosed }
        let requestData = try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:])
        let resultData = try await client.sendRequest(
            requestData,
            timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
        )
        let response = try MobileSyncWorkspaceListResponse.decode(resultData)
        return response.workspaces.map { remote in
            var workspace = MobileWorkspacePreview(remote: remote)
            workspace.macDeviceID = macDeviceID
            return workspace
        }
    }
}
