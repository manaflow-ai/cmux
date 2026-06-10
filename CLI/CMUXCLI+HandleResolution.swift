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


// MARK: - ID and handle normalization/formatting
extension CMUXCLI {
    func formatIDs(_ object: Any, mode: CLIIDFormat) -> Any {
        switch object {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = formatIDs(v, mode: mode)
            }

            switch mode {
            case .both:
                break
            case .refs:
                if out["ref"] != nil && out["id"] != nil {
                    out.removeValue(forKey: "id")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_id") {
                    let prefix = String(key.dropLast(3))
                    if out["\(prefix)_ref"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_ids") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_refs"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            case .uuids:
                if out["id"] != nil && out["ref"] != nil {
                    out.removeValue(forKey: "ref")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_ref") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_id"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_refs") {
                    let prefix = String(key.dropLast(5))
                    if out["\(prefix)_ids"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            }
            return out

        case let array as [Any]:
            return array.map { formatIDs($0, mode: mode) }

        default:
            return object
        }
    }

    func intFromAny(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    func doubleFromAny(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    func boolFromAny(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber {
            let numeric = number.doubleValue
            if numeric == 0 { return false }
            if numeric == 1 { return true }
            return nil
        }
        if let string = value as? String {
            return parseBoolString(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func parseBoolString(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func parsePositiveInt(_ raw: String?, label: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw) else {
            throw CLIError(message: "\(label) must be an integer")
        }
        return value
    }

    func isHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "pane", "surface"].contains(kind) else { return false }
        return Int(String(pieces[1])) != nil
    }

    func normalizeWindowHandle(_ raw: String?, client: SocketClient, allowCurrent: Bool = false) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "window.current")
            return (current["window_ref"] as? String) ?? (current["window_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) {
            return trimmed
        }
        if isHandleRef(trimmed) {
            if let matched = try matchingWindowHandle(trimmed, client: client) {
                return matched
            }
            throw CLIError(message: "Window not found: \(trimmed)")
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid window handle: \(trimmed) (expected UUID, ref like window:1, or index)")
        }

        let listed = try client.sendV2(method: "window.list")
        let windows = listed["windows"] as? [[String: Any]] ?? []
        for item in windows where intFromAny(item["index"]) == wantedIndex {
            return (item["id"] as? String) ?? (item["ref"] as? String)
        }
        throw CLIError(message: "Window index not found")
    }

    private func matchingWindowHandle(_ handle: String, client: SocketClient) throws -> String? {
        let listed = try client.sendV2(method: "window.list")
        let windows = listed["windows"] as? [[String: Any]] ?? []
        for window in windows where windowHandleMatches(handle, item: window) {
            return (window["id"] as? String) ?? (window["ref"] as? String) ?? handle
        }
        return nil
    }

    private func windowHandleMatches(_ handle: String, item: [String: Any]) -> Bool {
        guard let target = normalizedHandleValue(handle) else { return false }
        for candidate in [item["id"] as? String, item["ref"] as? String] {
            guard let candidate = normalizedHandleValue(candidate) else { continue }
            if handlesMatch(target, candidate) {
                return true
            }
        }
        return false
    }

    func validatedWindowHandle(_ raw: String?, client: SocketClient) throws -> String? {
        guard let raw else { return nil }
        guard let normalized = try normalizeWindowHandle(raw, client: client) else { return nil }

        let listed = try client.sendV2(method: "window.list")
        let windows = listed["windows"] as? [[String: Any]] ?? []
        let found = windows.contains { item in
            windowHandleMatches(normalized, item: item)
        }
        guard found else {
            throw CLIError(message: "Window not found: \(raw)")
        }
        return normalized
    }

    func normalizeWorkspaceHandle(
        _ raw: String?,
        client: SocketClient,
        windowHandle: String? = nil,
        allowCurrent: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current: [String: Any]
            if let windowHandle {
                current = try client.sendV2(method: "workspace.current", params: ["window_id": windowHandle])
            } else {
                current = try client.sendV2(method: "workspace.current")
            }
            return (current["workspace_id"] as? String) ?? (current["workspace_ref"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) {
            return trimmed
        }
        if isHandleRef(trimmed) {
            guard windowHandle != nil else { return trimmed }
            return try resolveWorkspaceId(trimmed, client: client, windowHandle: windowHandle)
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid workspace handle: \(trimmed) (expected UUID, ref like workspace:1, or index)")
        }

        var params: [String: Any] = [:]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let listed = try client.sendV2(method: "workspace.list", params: params)
        let items = listed["workspaces"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["id"] as? String) ?? (item["ref"] as? String)
        }
        throw CLIError(message: "Workspace index not found")
    }

    func normalizePaneHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        windowHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            if workspaceHandle != nil { return nil }
            let params: [String: Any] = windowHandle.map { ["window_id": $0] } ?? [:]
            let ident = try client.sendV2(method: "system.identify", params: params)
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["pane_id"] as? String) ?? (focused["pane_ref"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            if let windowHandle {
                return try validatePaneHandleInWindow(
                    trimmed,
                    client: client,
                    workspaceHandle: workspaceHandle,
                    windowHandle: windowHandle
                )
            }
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid pane handle: \(trimmed) (expected UUID, ref like pane:1, or index)")
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let listed = try client.sendV2(method: "pane.list", params: params)
        let items = listed["panes"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["id"] as? String) ?? (item["ref"] as? String)
        }
        throw CLIError(message: "Pane index not found")
    }

    private func validatePaneHandleInWindow(
        _ paneHandle: String,
        client: SocketClient,
        workspaceHandle: String?,
        windowHandle: String
    ) throws -> String {
        if let workspaceHandle {
            if let matched = try matchingPaneHandleInWorkspace(
                paneHandle,
                client: client,
                workspaceHandle: workspaceHandle,
                windowHandle: windowHandle
            ) {
                return matched
            }
            throw CLIError(message: "Pane not found in window")
        }

        let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowHandle])
        let workspaces = listed["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces {
            guard let workspaceHandle = (workspace["id"] as? String) ?? (workspace["ref"] as? String) else {
                continue
            }
            if let matched = try matchingPaneHandleInWorkspace(
                paneHandle,
                client: client,
                workspaceHandle: workspaceHandle,
                windowHandle: windowHandle
            ) {
                return matched
            }
        }
        throw CLIError(message: "Pane not found in window")
    }

    private func matchingPaneHandleInWorkspace(
        _ paneHandle: String,
        client: SocketClient,
        workspaceHandle: String,
        windowHandle: String
    ) throws -> String? {
        let listed = try client.sendV2(
            method: "pane.list",
            params: [
                "workspace_id": workspaceHandle,
                "window_id": windowHandle,
            ]
        )
        let panes = listed["panes"] as? [[String: Any]] ?? []
        for pane in panes where paneHandleMatches(paneHandle, item: pane) {
            return (pane["id"] as? String) ?? (pane["ref"] as? String) ?? paneHandle
        }
        return nil
    }

    private func paneHandleMatches(_ handle: String, item: [String: Any]) -> Bool {
        guard let target = normalizedHandleValue(handle) else { return false }
        for candidate in [item["id"] as? String, item["ref"] as? String] {
            guard let candidate = normalizedHandleValue(candidate) else { continue }
            if handlesMatch(target, candidate) {
                return true
            }
        }
        return false
    }

    private func handlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsUUID = UUID(uuidString: lhs),
           let rhsUUID = UUID(uuidString: rhs) {
            return lhsUUID == rhsUUID
        }
        return lhs.lowercased() == rhs.lowercased()
    }

    func normalizeSurfaceHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        windowHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            if workspaceHandle != nil { return nil }
            let params: [String: Any] = windowHandle.map { ["window_id": $0] } ?? [:]
            let ident = try client.sendV2(method: "system.identify", params: params)
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["surface_id"] as? String) ?? (focused["surface_ref"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            if let windowHandle {
                return try validateSurfaceHandleInWindow(
                    trimmed,
                    client: client,
                    workspaceHandle: workspaceHandle,
                    windowHandle: windowHandle
                )
            }
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid surface handle: \(trimmed) (expected UUID, ref like surface:1, or index)")
        }

        var params: [String: Any] = [:]
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        let listed = try client.sendV2(method: "surface.list", params: params)
        let items = listed["surfaces"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["id"] as? String) ?? (item["ref"] as? String)
        }
        throw CLIError(message: "Surface index not found")
    }

    private func validateSurfaceHandleInWindow(
        _ surfaceHandle: String,
        client: SocketClient,
        workspaceHandle: String?,
        windowHandle: String
    ) throws -> String {
        if let workspaceHandle {
            if let matched = try matchingSurfaceHandleInWorkspace(
                surfaceHandle,
                client: client,
                workspaceHandle: workspaceHandle,
                windowHandle: windowHandle
            ) {
                return matched
            }
            throw CLIError(message: "Surface not found in window")
        }

        let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowHandle])
        let workspaces = listed["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces {
            guard let workspaceHandle = (workspace["id"] as? String) ?? (workspace["ref"] as? String) else {
                continue
            }
            if let matched = try matchingSurfaceHandleInWorkspace(
                surfaceHandle,
                client: client,
                workspaceHandle: workspaceHandle,
                windowHandle: windowHandle
            ) {
                return matched
            }
        }
        throw CLIError(message: "Surface not found in window")
    }

    private func matchingSurfaceHandleInWorkspace(
        _ surfaceHandle: String,
        client: SocketClient,
        workspaceHandle: String,
        windowHandle: String
    ) throws -> String? {
        let listed = try client.sendV2(
            method: "surface.list",
            params: [
                "workspace_id": workspaceHandle,
                "window_id": windowHandle,
            ]
        )
        let surfaces = listed["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces where surfaceHandleMatches(surfaceHandle, item: surface) {
            return (surface["id"] as? String) ?? (surface["ref"] as? String) ?? surfaceHandle
        }
        return nil
    }

    func surfaceHandleMatches(_ handle: String, item: [String: Any]) -> Bool {
        guard let target = normalizedHandleValue(handle) else { return false }
        for candidate in [item["id"] as? String, item["ref"] as? String] {
            guard let candidate = normalizedHandleValue(candidate) else { continue }
            if handlesMatch(target, candidate) {
                return true
            }
        }
        return false
    }

    private func canonicalSurfaceHandleFromTabInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "tab",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "surface:\(ordinal)"
    }

    func normalizeTabHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        windowHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            return try normalizeSurfaceHandle(
                nil,
                client: client,
                workspaceHandle: workspaceHandle,
                windowHandle: windowHandle,
                allowFocused: allowFocused
            )
        }

        let canonical = canonicalSurfaceHandleFromTabInput(raw)
        return try normalizeSurfaceHandle(
            canonical,
            client: client,
            workspaceHandle: workspaceHandle,
            windowHandle: windowHandle,
            allowFocused: false
        )
    }

    private func displayTabHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              String(pieces[0]).lowercased() == "surface",
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "tab:\(ordinal)"
    }

    func formatHandle(_ payload: [String: Any], kind: String, idFormat: CLIIDFormat) -> String? {
        let id = payload["\(kind)_id"] as? String
        let ref = payload["\(kind)_ref"] as? String
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    func formatTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["tab_id"] as? String) ?? (payload["surface_id"] as? String)
        let refRaw = (payload["tab_ref"] as? String) ?? (payload["surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    func formatCreatedTabHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["created_tab_id"] as? String) ?? (payload["created_surface_id"] as? String)
        let refRaw = (payload["created_tab_ref"] as? String) ?? (payload["created_surface_ref"] as? String)
        let ref = displayTabHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    func printV2Payload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallbackText)
        }
    }

}
