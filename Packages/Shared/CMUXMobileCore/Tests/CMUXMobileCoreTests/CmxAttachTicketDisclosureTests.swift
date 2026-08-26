import Foundation
import Testing
@testable import CMUXMobileCore

@Test func authenticatedTicketDisclosurePreservesFieldsAndRoutes() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831),
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

    #expect(disclosed == ticket)
}

@Test func publicStatusDisclosureExposesNoRoutes() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )

    #expect(route.disclosed(for: .publicStatus, at: now) == nil)
    #expect(route.disclosed(for: .authenticated, at: now) == route)
    #expect(route.disclosed(for: .cloudRendezvous, at: now) == route)
    #expect(route.disclosed(for: .pairedMacCloudBackup, at: now) == route)
}
