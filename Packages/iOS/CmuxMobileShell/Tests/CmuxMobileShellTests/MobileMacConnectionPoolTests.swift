import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileMacConnectionPoolTests {
    @Test func controlTopicsCarryAggregateStateWithoutTerminalRenderTraffic() {
        #expect(SecondaryMacSubscription.eventTopics.contains("workspace.updated"))
        #expect(SecondaryMacSubscription.eventTopics.contains("mobile.sync.delta"))
        #expect(SecondaryMacSubscription.eventTopics.contains("notification.feed.changed"))
        #expect(!SecondaryMacSubscription.eventTopics.contains {
            $0.hasPrefix("terminal.")
        })
    }

    @Test func presenceLimitsControlPoolCandidatesToOnlinePairedMacs() throws {
        let store = MobileShellComposite(
            isSignedIn: false,
            presence: IdlePresence()
        )
        let online = try Self.pairedMac(id: "mac-online", instanceTag: "tag-online")
        let offline = try Self.pairedMac(id: "mac-offline", instanceTag: "tag-offline")
        store.applyPresenceUpdate(
            Self.snapshot([
                Self.instance(
                    deviceID: online.macDeviceID,
                    tag: "tag-online",
                    online: true
                ),
                Self.instance(
                    deviceID: offline.macDeviceID,
                    tag: "tag-offline",
                    online: false
                ),
            ]),
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-1",
                generation: 0
            )
        )

        let candidates = store.secondaryAggregationCandidateMacs(
            from: [online, offline]
        )

        #expect(candidates.map(\.macDeviceID) == ["mac-online"])
    }

    private static func pairedMac(
        id: String,
        instanceTag: String
    ) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: id,
            routes: [try CmxAttachRoute(
                id: "\(id)-route",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.64.0.1", port: 50_922)
            )],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-1",
            instanceTag: instanceTag
        )
    }

    private static func instance(
        deviceID: String,
        tag: String,
        online: Bool
    ) -> PresenceInstance {
        PresenceInstance(
            deviceId: deviceID,
            tag: tag,
            platform: "mac",
            online: online,
            lastSeenAt: 1_000
        )
    }

    private static func snapshot(
        _ instances: [PresenceInstance]
    ) -> PresenceUpdate {
        .snapshot(PresenceSnapshot(
            teamId: "team-1",
            now: 1_000,
            heartbeatIntervalMs: 15_000,
            offlineTimeoutMs: 45_000,
            devices: instances.map { instance in
                PresenceDevice(
                    deviceId: instance.deviceId,
                    platform: instance.platform,
                    displayName: instance.displayName,
                    online: instance.online,
                    lastSeenAt: instance.lastSeenAt,
                    instances: [instance]
                )
            }
        ))
    }
}

private struct IdlePresence: PresenceSubscribing {
    func subscribe() async throws -> AsyncThrowingStream<PresenceUpdate, any Error> {
        AsyncThrowingStream { _ in }
    }
}
