import Foundation

extension TerminalController {
    nonisolated static func surfaceMachinePayload(_ info: SurfaceMachineInfo) -> [String: Any] {
        var presence: Any = NSNull()
        if let record = info.presence {
            presence = [
                "state": record.state.rawValue,
                "last_seen_at": record.lastSeenAt.map { $0.timeIntervalSince1970 } ?? NSNull(),
                "tag": record.tag,
                "bundle_id": record.bundleID ?? NSNull(),
                "account_trust": record.accountTrust.rawValue,
                "build_label": record.buildLabel ?? NSNull(),
            ] as [String: Any]
        }
        let kind: String
        switch info.id {
        case .local: kind = "local"
        case .cloud: kind = "cloud"
        case .ssh: kind = "ssh"
        case .device: kind = "device"
        }
        return [
            "id": info.id.rawValue,
            "local": info.id.isLocal,
            "kind": kind,
            "presence": presence,
            "port_discovery_state": info.portDiscoveryState.wireValue,
            "name": info.name,
            "status": info.status,
            "image": info.image ?? NSNull(),
            "has_desktop": info.hasDesktop,
            "memory_mb": info.memoryMb ?? NSNull(),
            "disk_mb": info.diskMb ?? NSNull(),
            "link_state": info.linkState.rawValue,
            "link_error": info.linkError ?? NSNull(),
            "cpu_percent": info.cpuPercent ?? NSNull(),
            "memory_used_mb": info.memoryUsedMb ?? NSNull(),
            "disk_used_mb": info.diskUsedMb ?? NSNull(),
            "remote_workspaces": info.remoteWorkspaces.map { $0.map(surfaceRemoteWorkspacePayload) } ?? NSNull(),
        ]
    }
}
