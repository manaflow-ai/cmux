import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell
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
            agentSessionID: "agent-new",
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
        #expect(snapshots.first?.agentSessionID == newer.agentSessionID)
    }

    @Test func minimalPollingPayloadDecodesIntoFreshHandoffSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_010)
        let lastSeenAt = now.addingTimeInterval(-10).formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
        let payload: [String: Any] = [
            "devices": [[
                "deviceId": "mac-review",
                "platform": "mac",
                "instances": [[
                    "tag": "stable",
                    "lastSeenAt": lastSeenAt,
                    "routes": [[
                        "id": "review-route",
                        "kind": "tailscale",
                        "endpoint": [
                            "type": "host_port",
                            "host": "desktop.example.ts.net",
                            "port": 51001,
                        ],
                    ]],
                    "sessions": [[
                        "id": "review-session",
                        "workspaceID": "review-workspace",
                        "title": "App Review",
                        "status": "idle",
                        "lastActivityAt": 1_800_000_000,
                    ]],
                ]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let devices = try #require(DeviceRegistryService.parseDeviceList(in: data))
        let snapshots = RegistryLiveSessionSnapshot.snapshots(from: devices, now: now)

        #expect(snapshots.map(\.sessionID) == ["review-session"])
        #expect(snapshots.first?.workspaceTitle == "App Review")
    }
}
