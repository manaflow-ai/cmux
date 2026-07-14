import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// Immutable presentation snapshot for one account-discovered live session.
struct RegistryLiveSessionSnapshot: Equatable, Identifiable {
    let id: String
    let deviceID: String
    let instanceTag: String
    let sessionID: String
    let workspaceTitle: String
    let deviceTitle: String
    let agent: String?
    let status: CmxLiveSessionStatus
    let lastActivityAt: Date

    /// Flatten attachable registry instances into newest-first handoff rows.
    static func snapshots(from devices: [RegistryDevice]) -> [RegistryLiveSessionSnapshot] {
        devices
            .filter(\.isControllableHost)
            .flatMap { device in
                device.instances
                    .filter(\.hasRoutes)
                    .flatMap { instance in
                        instance.sessions.map { session in
                            RegistryLiveSessionSnapshot(
                                id: "\(device.deviceId)|\(instance.tag)|\(session.id)",
                                deviceID: device.deviceId,
                                instanceTag: instance.tag,
                                sessionID: session.id,
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
