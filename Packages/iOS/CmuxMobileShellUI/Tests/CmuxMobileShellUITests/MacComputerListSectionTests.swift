import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct MacComputerListSectionTests {
    private let peerID = String(repeating: "ab", count: 32)

    @Test func macWithSeveralMethodsAppearsOncePerMethod() throws {
        let mac = snapshot(
            deviceId: "mac-1",
            routes: [
                try CmxAttachRoute(
                    id: "r-iroh",
                    kind: .iroh,
                    endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: peerID), pathHints: [])
                ),
                try CmxAttachRoute(
                    id: "r-ts",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "mac-1.ts.net", port: 5100)
                ),
            ]
        )

        let sections = MacComputerListSection.sections(from: [mac])

        #expect(sections.map(\.kind) == [.iroh, .tailscale])
        #expect(sections.allSatisfy { $0.computers.map(\.id) == [mac.id] })
        // Each row shows its own method's endpoint, not the preferred one.
        #expect(sections[0].computers[0].routeDescription == "\(peerID.prefix(12))…")
        #expect(sections[1].computers[0].routeDescription == "mac-1.ts.net:5100")
    }

    @Test func routelessMacsLandInTrailingNoRouteSection() throws {
        let reachable = snapshot(
            deviceId: "mac-1",
            routes: [
                try CmxAttachRoute(
                    id: "r-ts",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "mac-1.ts.net", port: 5100)
                )
            ]
        )
        let stale = snapshot(deviceId: "mac-2", routes: [])

        let sections = MacComputerListSection.sections(from: [reachable, stale])

        #expect(sections.map(\.kind) == [.tailscale, nil])
        #expect(sections[1].computers.map(\.deviceId) == ["mac-2"])
    }

    @Test func sectionsFollowDialPreferenceOrderAndSkipEmptyKinds() throws {
        let tailscaleOnly = snapshot(
            deviceId: "mac-ts",
            routes: [
                try CmxAttachRoute(
                    id: "r-ts",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "mac-ts.ts.net", port: 5100)
                )
            ]
        )
        let irohOnly = snapshot(
            deviceId: "mac-iroh",
            routes: [
                try CmxAttachRoute(
                    id: "r-iroh",
                    kind: .iroh,
                    endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: peerID), pathHints: [])
                )
            ]
        )

        // Input order is tailscale-first; sections still lead with Auto-Connect.
        let sections = MacComputerListSection.sections(from: [tailscaleOnly, irohOnly])

        #expect(sections.map(\.kind) == [.iroh, .tailscale])
        #expect(sections[0].computers.map(\.deviceId) == ["mac-iroh"])
        #expect(sections[1].computers.map(\.deviceId) == ["mac-ts"])
    }

    @Test func duplicateRoutesOfOneKindProduceOneRowWithTheFirstEndpoint() throws {
        let mac = snapshot(
            deviceId: "mac-1",
            routes: [
                try CmxAttachRoute(
                    id: "r-ts-1",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "primary.ts.net", port: 5100)
                ),
                try CmxAttachRoute(
                    id: "r-ts-2",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "secondary.ts.net", port: 5100)
                ),
            ]
        )

        let sections = MacComputerListSection.sections(from: [mac])

        #expect(sections.map(\.kind) == [.tailscale])
        #expect(sections[0].computers.count == 1)
        #expect(sections[0].computers[0].routeDescription == "primary.ts.net:5100")
    }

    @Test func activeKindSectionLeadsAndIsFlagged() throws {
        let mac = snapshot(
            deviceId: "mac-1",
            routes: [
                try CmxAttachRoute(
                    id: "r-iroh",
                    kind: .iroh,
                    endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: peerID), pathHints: [])
                ),
                try CmxAttachRoute(
                    id: "r-ts",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "mac-1.ts.net", port: 5100)
                ),
            ]
        )

        // Tailscale carries the live connection: it outranks dial preference.
        let sections = MacComputerListSection.sections(from: [mac], activeKind: .tailscale)

        #expect(sections.map(\.kind) == [.tailscale, .iroh])
        #expect(sections.map(\.isActive) == [true, false])
    }

    @Test func noActiveKindKeepsDialPreferenceOrderAndFlagsNothing() throws {
        let mac = snapshot(
            deviceId: "mac-1",
            routes: [
                try CmxAttachRoute(
                    id: "r-iroh",
                    kind: .iroh,
                    endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: peerID), pathHints: [])
                ),
                try CmxAttachRoute(
                    id: "r-ts",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "mac-1.ts.net", port: 5100)
                ),
            ]
        )

        let sections = MacComputerListSection.sections(from: [mac], activeKind: nil)

        #expect(sections.map(\.kind) == [.iroh, .tailscale])
        #expect(sections.allSatisfy { !$0.isActive })
    }

    @Test func debugRoutesRenderNoSectionWhenExcluded() throws {
        let mac = snapshot(
            deviceId: "mac-1",
            routes: [
                try CmxAttachRoute(
                    id: "r-debug",
                    kind: .debugLoopback,
                    endpoint: .hostPort(host: "127.0.0.1", port: 5100)
                ),
                try CmxAttachRoute(
                    id: "r-ts",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "mac-1.ts.net", port: 5100)
                ),
            ]
        )

        let sections = MacComputerListSection.sections(from: [mac], includeDebug: false)

        #expect(sections.map(\.kind) == [.tailscale])
    }

    @Test func debugOnlyMacFallsToNoRouteWhenDebugExcluded() throws {
        let mac = snapshot(
            deviceId: "mac-1",
            routes: [
                try CmxAttachRoute(
                    id: "r-debug",
                    kind: .debugLoopback,
                    endpoint: .hostPort(host: "127.0.0.1", port: 5100)
                )
            ]
        )

        let sections = MacComputerListSection.sections(from: [mac], includeDebug: false)

        #expect(sections.map(\.kind) == [nil])
        #expect(sections[0].computers.map(\.deviceId) == ["mac-1"])
    }

    private func snapshot(deviceId: String, routes: [CmxAttachRoute]) -> MacComputerSnapshot {
        MacComputerSnapshot(
            deviceId: deviceId,
            instanceTag: nil,
            title: deviceId,
            platform: "mac",
            colorIndex: nil,
            customColor: nil,
            customIcon: nil,
            connectionStatus: nil,
            presence: nil,
            buildLabel: nil,
            routeDescription: CmxAttachRoute.deviceTreeRouteDescription(for: routes),
            routes: routes,
            lastSeenAt: Date(timeIntervalSince1970: 0),
            workspaceCount: 0,
            aliasIDs: [deviceId]
        )
    }
}
