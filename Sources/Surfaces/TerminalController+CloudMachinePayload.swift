import Foundation

extension TerminalController {
    nonisolated static func surfaceMachinePayload(_ info: SurfaceMachineInfo) -> [String: Any] {
        [
            "id": info.id.rawValue,
            "local": info.id.isLocal,
            "name": info.name,
            "status": info.status,
            "image": info.image ?? NSNull(),
            "has_desktop": info.hasDesktop,
            "memory_mb": info.memoryMb ?? NSNull(),
            "disk_mb": info.diskMb ?? NSNull(),
            "port_discovery_state": info.portDiscoveryState.wireValue,
            "link_state": info.linkState.rawValue,
            "link_error": info.linkError ?? NSNull(),
            "cpu_percent": info.cpuPercent ?? NSNull(),
            "memory_used_mb": info.memoryUsedMb ?? NSNull(),
            "disk_used_mb": info.diskUsedMb ?? NSNull(),
            "remote_workspaces": info.remoteWorkspaces.map { $0.map(surfaceRemoteWorkspacePayload) } ?? NSNull(),
        ]
    }

}
