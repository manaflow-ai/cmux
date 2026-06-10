import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Remote relay ID alias rewriting
extension Workspace {
    private nonisolated static let remoteRelayWorkspaceIDKeys: Set<String> = [
        "workspace_id",
        "preferred_workspace_id",
        "selected_workspace_id",
        "before_workspace_id",
        "after_workspace_id",
        "from_workspace_id",
        "to_workspace_id",
    ]

    private nonisolated static let remoteRelaySurfaceIDKeys: Set<String> = [
        "panel_id",
        "surface_id",
        "preferred_panel_id",
        "preferred_surface_id",
        "target_panel_id",
        "target_surface_id",
        "created_panel_id",
        "created_surface_id",
        "before_panel_id",
        "before_surface_id",
        "after_panel_id",
        "after_surface_id",
    ]

    private nonisolated static let remoteRelayAmbiguousIDKeys: Set<String> = [
        "tab_id",
    ]

    private nonisolated static let remoteRelayWorkspaceIDArrayKeys: Set<String> = [
        "workspace_ids",
    ]

    private nonisolated static let remoteRelaySurfaceIDArrayKeys: Set<String> = [
        "panel_ids",
        "surface_ids",
    ]

    private nonisolated static let remoteRelayAmbiguousIDArrayKeys: Set<String> = [
        "tab_ids",
        "tab_id_groups",
    ]

    func syncRemoteRelayIDAliasesToController() {
        remoteSessionController?.updateRemoteRelayIDAliases(
            workspaceAliases: remoteRelayWorkspaceIDAliases,
            surfaceAliases: remoteRelaySurfaceIDAliases
        )
    }

    func clearRemoteRelayIDAliases() {
        guard !remoteRelayWorkspaceIDAliases.isEmpty || !remoteRelaySurfaceIDAliases.isEmpty else { return }
        remoteRelayWorkspaceIDAliases.removeAll()
        remoteRelaySurfaceIDAliases.removeAll()
        syncRemoteRelayIDAliasesToController()
    }

    func pruneRemoteRelaySurfaceAliases(validSurfaceIds: Set<UUID>) {
        let nextAliases = remoteRelaySurfaceIDAliases.filter { validSurfaceIds.contains($0.value) }
        guard nextAliases != remoteRelaySurfaceIDAliases else { return }
        remoteRelaySurfaceIDAliases = nextAliases
        syncRemoteRelayIDAliasesToController()
    }

    func removeRemoteRelaySurfaceAliases(targeting panelId: UUID) {
        let nextAliases = remoteRelaySurfaceIDAliases.filter { $0.value != panelId }
        guard nextAliases != remoteRelaySurfaceIDAliases else { return }
        remoteRelaySurfaceIDAliases = nextAliases
        syncRemoteRelayIDAliasesToController()
    }

    func registerRemoteRelayIDAliases(
        snapshotWorkspaceId: UUID?,
        snapshotPanelId: UUID,
        restoredPanelId: UUID
    ) {
        var didMutate = false
        if let snapshotWorkspaceId, snapshotWorkspaceId != id {
            if remoteRelayWorkspaceIDAliases[snapshotWorkspaceId] != id {
                remoteRelayWorkspaceIDAliases[snapshotWorkspaceId] = id
                didMutate = true
            }
        }
        if snapshotPanelId != restoredPanelId {
            if remoteRelaySurfaceIDAliases[snapshotPanelId] != restoredPanelId {
                remoteRelaySurfaceIDAliases[snapshotPanelId] = restoredPanelId
                didMutate = true
            }
        }
        if didMutate {
            syncRemoteRelayIDAliasesToController()
        }
    }

    func registerRemoteRelayIDAliases(remotePTYSessionID: String, restoredPanelId: UUID) {
        guard let parsed = Self.parsedDefaultSSHPTYSessionID(remotePTYSessionID) else { return }
        registerRemoteRelayIDAliases(
            snapshotWorkspaceId: parsed.workspaceId,
            snapshotPanelId: parsed.panelId,
            restoredPanelId: restoredPanelId
        )
    }

    func rewriteRemoteRelayCommandLine(_ commandLine: Data) -> Data {
        Self.rewriteRemoteRelayCommandLine(
            commandLine,
            workspaceAliases: remoteRelayWorkspaceIDAliases,
            surfaceAliases: remoteRelaySurfaceIDAliases
        )
    }

    nonisolated static func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        guard !workspaceAliases.isEmpty || !surfaceAliases.isEmpty,
              let line = String(data: commandLine, encoding: .utf8) else {
            return commandLine
        }
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("{"),
              let requestData = trimmedLine.data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return commandLine
        }

        var didRewrite = false
        if let params = request["params"] as? [String: Any] {
            request["params"] = Self.remappedRemoteRelayValue(
                params,
                key: nil,
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases,
                didRewrite: &didRewrite
            )
        }

        guard didRewrite,
              JSONSerialization.isValidJSONObject(request),
              let rewritten = try? JSONSerialization.data(withJSONObject: request, options: []) else {
            return commandLine
        }
        if commandLine.last == 0x0A {
            return rewritten + Data([0x0A])
        }
        return rewritten
    }

    private nonisolated static func remappedRemoteRelayValue(
        _ value: Any,
        key: String?,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID],
        didRewrite: inout Bool
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = dictionary
            for (childKey, childValue) in dictionary {
                result[childKey] = remappedRemoteRelayValue(
                    childValue,
                    key: childKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases,
                    didRewrite: &didRewrite
                )
            }
            return result
        }

        if let array = value as? [Any] {
            let elementKey: String?
            if let key, remoteRelayWorkspaceIDArrayKeys.contains(key) {
                elementKey = "workspace_id"
            } else if let key, remoteRelaySurfaceIDArrayKeys.contains(key) {
                elementKey = "surface_id"
            } else if let key, remoteRelayAmbiguousIDArrayKeys.contains(key) {
                elementKey = "tab_id"
            } else if let key, remoteRelayWorkspaceIDKeys.contains(key)
                        || remoteRelaySurfaceIDKeys.contains(key)
                        || remoteRelayAmbiguousIDKeys.contains(key) {
                elementKey = key
            } else {
                elementKey = nil
            }
            return array.map {
                remappedRemoteRelayValue(
                    $0,
                    key: elementKey,
                    workspaceAliases: workspaceAliases,
                    surfaceAliases: surfaceAliases,
                    didRewrite: &didRewrite
                )
            }
        }

        guard let id = value as? String else {
            return value
        }

        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmedID) else {
            return value
        }

        guard let key else {
            return value
        }
        if remoteRelaySurfaceIDKeys.contains(key),
           let mapped = surfaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        if remoteRelayWorkspaceIDKeys.contains(key),
           let mapped = workspaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        guard remoteRelayAmbiguousIDKeys.contains(key) else {
            return value
        }

        if let mapped = workspaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }
        if let mapped = surfaceAliases[uuid] {
            didRewrite = true
            return mapped.uuidString
        }

        return value
    }

}
