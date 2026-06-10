import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Window/notification response parsing
extension CMUXCLI {
    func parseWindows(_ response: String) -> [WindowInfo] {
        guard response != "No windows" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let key = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2 else { return nil }
                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = parts[1]

                var selectedWorkspaceId: String?
                var workspaceCount: Int = 0
                for token in parts.dropFirst(2) {
                    if token.hasPrefix("selected_workspace=") {
                        let v = token.replacingOccurrences(of: "selected_workspace=", with: "")
                        selectedWorkspaceId = (v == "none") ? nil : v
                    } else if token.hasPrefix("workspaces=") {
                        let v = token.replacingOccurrences(of: "workspaces=", with: "")
                        workspaceCount = Int(v) ?? 0
                    }
                }

                return WindowInfo(
                    index: index,
                    id: id,
                    key: key,
                    selectedWorkspaceId: selectedWorkspaceId,
                    workspaceCount: workspaceCount
                )
            }
    }

    func parseNotifications(_ response: String) -> [NotificationInfo] {
        guard response != "No notifications" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let payload = parts[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard payload.count >= 7 else { return nil }
                let notifId = payload[0]
                let workspaceId = payload[1]
                let surfaceRaw = payload[2]
                let surfaceId = surfaceRaw == "none" ? nil : surfaceRaw
                let readText = payload[3]
                let title = payload[4]
                let subtitle = payload[5]
                let body: String
                let createdAt: String?
                let tabTitle: String?
                let trailingTabTitle = payload.count >= 9 ? decodeNotificationListTrailingField(payload[payload.count - 1]) : nil
                if payload.count >= 9,
                   isNotificationListCreatedAtField(payload[payload.count - 2]),
                   let trailingTabTitle {
                    body = payload[6..<(payload.count - 2)].joined(separator: "|")
                    createdAt = payload[payload.count - 2].isEmpty ? nil : payload[payload.count - 2]
                    tabTitle = trailingTabTitle.isEmpty ? nil : trailingTabTitle
                } else {
                    body = payload[6...].joined(separator: "|")
                    createdAt = nil
                    tabTitle = nil
                }
                return NotificationInfo(
                    id: notifId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    isRead: readText == "read",
                    title: title,
                    subtitle: subtitle,
                    body: body,
                    createdAt: createdAt,
                    tabTitle: tabTitle
                )
            }
    }

    private func isNotificationListCreatedAtField(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private func decodeNotificationListTrailingField(_ value: String) -> String? {
        guard value.hasPrefix("pct:") else { return nil }
        return String(value.dropFirst(4))
            .replacingOccurrences(of: "%0D", with: "\r")
            .replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%7C", with: "|")
            .replacingOccurrences(of: "%25", with: "%")
    }

    func resolveWorkspaceId(_ raw: String?, client: SocketClient, windowHandle: String? = nil) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            if let windowHandle {
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowHandle])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where (item["ref"] as? String) == raw {
                    if let id = item["id"] as? String { return id }
                }
            } else {
                // Resolve ref to UUID — search across all windows
                let windows = try client.sendV2(method: "window.list")
                let windowList = windows["windows"] as? [[String: Any]] ?? []
                for window in windowList {
                    guard let windowId = window["id"] as? String else { continue }
                    let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                    let items = listed["workspaces"] as? [[String: Any]] ?? []
                    for item in items where (item["ref"] as? String) == raw {
                        if let id = item["id"] as? String { return id }
                    }
                }
            }
            throw CLIError(message: "Workspace ref not found: \(raw)")
        }

        if let raw, let index = Int(raw) {
            var params: [String: Any] = [:]
            if let windowHandle { params["window_id"] = windowHandle }
            let listed = try client.sendV2(method: "workspace.list", params: params)
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Workspace index not found")
        }

        var currentParams: [String: Any] = [:]
        if let windowHandle {
            currentParams["window_id"] = windowHandle
        }
        let current = try client.sendV2(method: "workspace.current", params: currentParams)
        if let wsId = current["workspace_id"] as? String { return wsId }
        throw CLIError(message: "No workspace selected")
    }

    func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            for item in items where (item["ref"] as? String) == raw {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface ref not found: \(raw)")
        }

        let listed = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let items = listed["surfaces"] as? [[String: Any]] ?? []

        if let raw, let index = Int(raw) {
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "Surface index not found")
        }

        if let focused = items.first(where: { ($0["focused"] as? Bool) == true }) {
            if let id = focused["id"] as? String { return id }
        }

        throw CLIError(message: "Unable to resolve surface ID")
    }

    func resolveSurfaceTargetInWindow(
        _ raw: String,
        windowHandle: String,
        client: SocketClient
    ) throws -> (workspaceId: String, surfaceId: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Invalid surface handle")
        }
        let wantedIndex = Int(trimmed)
        if wantedIndex == nil, !isUUID(trimmed), !isHandleRef(trimmed) {
            throw CLIError(message: "Invalid surface handle: \(trimmed) (expected UUID, ref like surface:1, or index)")
        }

        if wantedIndex != nil {
            let workspaceId = try requireCurrentWorkspaceId(
                windowHandle: windowHandle,
                client: client,
                command: "notify"
            )
            let surfacePayload = try client.sendV2(
                method: "surface.list",
                params: [
                    "workspace_id": workspaceId,
                    "window_id": windowHandle,
                ]
            )
            let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
            for surface in surfaces where intFromAny(surface["index"]) == wantedIndex {
                if let surfaceId = surface["id"] as? String, !surfaceId.isEmpty {
                    return (workspaceId, surfaceId)
                }
            }
            throw CLIError(message: "Surface index not found in current workspace")
        }

        let workspacePayload = try client.sendV2(method: "workspace.list", params: ["window_id": windowHandle])
        let workspaces = workspacePayload["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces {
            guard let workspaceId = workspace["id"] as? String, !workspaceId.isEmpty else {
                continue
            }
            let surfacePayload = try client.sendV2(
                method: "surface.list",
                params: [
                    "workspace_id": workspaceId,
                    "window_id": windowHandle,
                ]
            )
            let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
            for surface in surfaces {
                let matchesIndex = wantedIndex.map { intFromAny(surface["index"]) == $0 } ?? false
                let matchesHandle = wantedIndex == nil && surfaceHandleMatches(trimmed, item: surface)
                guard matchesIndex || matchesHandle else { continue }
                if let surfaceId = surface["id"] as? String, !surfaceId.isEmpty {
                    return (workspaceId, surfaceId)
                }
            }
        }

        throw CLIError(message: "Surface not found in window")
    }

}
