import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// Immutable presentation snapshot for one account-private registry session.
struct RegistryLiveSessionSnapshot: Equatable, Identifiable {
    let id: String
    let deviceID: String
    let instanceTag: String
    let sessionID: String
    let agentSessionID: String?
    let workspaceTitle: String
    let deviceTitle: String
    let agent: String?
    let status: CmxLiveSessionStatus
    let lastActivityAt: Date

    /// Flatten attachable registry instances into newest-first handoff rows.
    static func snapshots(
        from devices: [RegistryDevice],
        now: Date = Date()
    ) -> [RegistryLiveSessionSnapshot] {
        devices
            .filter(\.isControllableHost)
            .flatMap { device in
                device.instances
                    .filter { instance in
                        let age = now.timeIntervalSince(instance.lastSeenAt)
                        return instance.hasRoutes && age <= 120 && age >= -300
                    }
                    .flatMap { instance in
                        instance.sessions.map { session in
                            RegistryLiveSessionSnapshot(
                                id: "\(device.deviceId)|\(instance.tag)|\(session.id)",
                                deviceID: device.deviceId,
                                instanceTag: instance.tag,
                                sessionID: session.id,
                                agentSessionID: session.agentSessionID,
                                workspaceTitle: session.title,
                                deviceTitle: device.title,
                                agent: session.agent,
                                status: session.status,
                                lastActivityAt: Date(timeIntervalSince1970: session.lastActivityAt)
                            )
                        }
                    }
            }
            .sorted { lhs, rhs in
                if lhs.lastActivityAt != rhs.lastActivityAt {
                    return lhs.lastActivityAt > rhs.lastActivityAt
                }
                return lhs.id < rhs.id
            }
    }
}
