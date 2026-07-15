import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct RegistryLiveSessionSnapshotTests {
    @Test func flattensOnlyAttachableHostSessionsNewestFirst() throws {
        let older = CmxLiveSession(
            id: "workspace-old",
            workspaceID: "workspace-old",
            title: "Older",
            status: .idle,
            lastActivityAt: 100
        )
        let newer = CmxLiveSession(
            id: "workspace-new",
            workspaceID: "workspace-new",
            title: "Newer",
            agent: "codex",
            status: .working,
            lastActivityAt: 200
        )
        let route = try CmxAttachRoute(
            id: "route",
            kind: .tailscale,
            endpoint: .hostPort(host: "desktop.example.ts.net", port: 51001)
        )
        let devices = [
            RegistryDevice(
                deviceId: "mac-a",
                platform: "mac",
                displayName: "Desk Mac",
                lastSeenAt: .now,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [route],
                        lastSeenAt: .now,
                        sessions: [older, newer]
                    ),
                    RegistryAppInstance(
                        tag: "offline",
                        routes: [],
                        lastSeenAt: .now,
                        sessions: [newer]
                    ),
                    RegistryAppInstance(
                        tag: "stale",
                        routes: [route],
                        lastSeenAt: Date(timeIntervalSince1970: 0),
                        sessions: [newer]
                    ),
                ]
            ),
            RegistryDevice(
                deviceId: "phone",
                platform: "ios",
                displayName: "Phone",
                lastSeenAt: .now,
                instances: [
                    RegistryAppInstance(tag: "app", routes: [route], lastSeenAt: .now, sessions: [newer])
                ]
            ),
        ]

        let snapshots = RegistryLiveSessionSnapshot.snapshots(from: devices)
        #expect(snapshots.map(\.sessionID) == ["workspace-new", "workspace-old"])
        #expect(snapshots.first?.deviceTitle == "Desk Mac")
        #expect(snapshots.first?.agent == "codex")
    }
}
