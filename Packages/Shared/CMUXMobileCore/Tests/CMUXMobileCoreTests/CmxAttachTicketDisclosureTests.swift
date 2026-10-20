import Foundation
import Testing
@testable import CMUXMobileCore

@Test func authenticatedTicketDisclosurePreservesFieldsAndFiltersRoutes() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let currentHint = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://relay.example.test/",
        source: .native,
        privacyScope: .publicInternet
    )
    let expiredHint = try CmxIrohPathHint(
        kind: .directAddress,
        value: "100.64.1.2:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: now.addingTimeInterval(-120),
        expiresAt: now.addingTimeInterval(-60),
        networkProfile: CmxIrohNetworkProfileKey(
            source: .tailscale,
            profileID: String(repeating: "a", count: 64)
        )
    )
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            identity: CmxIrohPeerIdentity(
                endpointID: String(repeating: "a", count: 64)
            ),
            pathHints: [expiredHint, currentHint]
        ),
        priority: 7
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace",
        terminalID: "terminal",
        macDeviceID: "mac-device",
        macDisplayName: "Mac",
        macUserEmail: "owner@example.test",
        macUserID: "user-id",
        macPairingCompatibilityVersion: 4,
        macAppVersion: "1.2.3",
        macAppBuild: "456",
        routes: [route],
        expiresAt: now.addingTimeInterval(300),
        authToken: "attach-token"
    )

    let disclosed = try ticket.authenticatedDisclosure(at: now)
    let disclosedRoute = try #require(route.disclosed(for: .authenticated, at: now))
    let expected = try CmxAttachTicket(
        version: ticket.version,
        workspaceID: ticket.workspaceID,
        terminalID: ticket.terminalID,
        macDeviceID: ticket.macDeviceID,
        macDisplayName: ticket.macDisplayName,
        macUserEmail: ticket.macUserEmail,
        macUserID: ticket.macUserID,
        macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
        macAppVersion: ticket.macAppVersion,
        macAppBuild: ticket.macAppBuild,
        routes: [disclosedRoute],
        expiresAt: ticket.expiresAt,
        authToken: ticket.authToken
    )

    #expect(disclosed == expected)
    guard case let .peer(_, pathHints) = disclosed.routes[0].endpoint else {
        Issue.record("Expected an Iroh peer route")
        return
    }
    #expect(pathHints == [currentHint])
}
