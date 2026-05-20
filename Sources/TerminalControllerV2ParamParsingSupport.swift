import Foundation
import Bonsplit

extension TerminalController {
    func v2String(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func v2StringArray(_ params: [String: Any], _ key: String) -> [String]? {
        if let raw = params[key] as? [String] {
            let normalized = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized
        }
        if let raw = params[key] as? [Any] {
            let normalized = raw
                .compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized
        }
        if let single = v2String(params, key) {
            return [single]
        }
        return nil
    }

    func v2StringMap(_ params: [String: Any], _ key: String) -> [String: String]? {
        guard let raw = params[key] else { return nil }
        if let dict = raw as? [String: String] {
            return dict
        }
        if let anyDict = raw as? [String: Any] {
            var out: [String: String] = [:]
            for (k, value) in anyDict {
                guard let stringValue = value as? String else { continue }
                out[k] = stringValue
            }
            return out
        }
        return nil
    }

    func v2ActionKey(_ params: [String: Any], _ key: String = "action") -> String? {
        guard let action = v2String(params, key) else { return nil }
        return action.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    func v2RawString(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    func v2OptionalTrimmedRawString(_ params: [String: Any], _ key: String) -> String? {
        let trimmed = v2RawString(params, key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    func v2InitialDividerPosition(_ params: [String: Any]) -> (value: Double?, error: V2CallResult?) {
        guard v2HasNonNullParam(params, "initial_divider_position") else {
            return (nil, nil)
        }
        guard let rawPosition = v2Double(params, "initial_divider_position"),
              rawPosition.isFinite else {
            return (
                nil,
                .err(code: "invalid_params", message: "initial_divider_position must be numeric", data: nil)
            )
        }
        return (min(max(rawPosition, 0.1), 0.9), nil)
    }

    func v2UUID(_ params: [String: Any], _ key: String) -> UUID? {
        guard let s = v2String(params, key) else { return nil }
        if let uuid = UUID(uuidString: s) {
            return uuid
        }
        return v2ResolveHandleRef(s)
    }

    func v2UUIDAny(_ raw: Any?) -> UUID? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid
        }
        return v2ResolveHandleRef(trimmed)
    }

    func v2Bool(_ params: [String: Any], _ key: String) -> Bool? {
        if let b = params[key] as? Bool { return b }
        if let n = params[key] as? NSNumber { return n.boolValue }
        if let s = params[key] as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func v2LocatePane(_ paneUUID: UUID) -> (windowId: UUID, tabManager: TabManager, workspace: Workspace, paneId: PaneID)? {
        guard let app = AppDelegate.shared else { return nil }
        let windows = app.listMainWindowSummaries()
        for item in windows {
            guard let tm = app.tabManagerFor(windowId: item.windowId) else { continue }
            for ws in tm.tabs {
                if let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) {
                    return (item.windowId, tm, ws, paneId)
                }
            }
        }
        return nil
    }

    func v2Int(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }

    func v2Double(_ params: [String: Any], _ key: String) -> Double? {
        if let d = params[key] as? Double { return d }
        if let f = params[key] as? Float { return Double(f) }
        if let n = params[key] as? NSNumber { return n.doubleValue }
        if let s = params[key] as? String { return Double(s) }
        return nil
    }

    func v2HasNonNullParam(_ params: [String: Any], _ key: String) -> Bool {
        guard let raw = params[key] else { return false }
        return !(raw is NSNull)
    }

    func v2StrictInt(_ params: [String: Any], _ key: String) -> Int? {
        v2StrictIntAny(params[key])
    }

    func v2StrictIntAny(_ raw: Any?) -> Int? {
        guard let raw else { return nil }

        if let numberValue = raw as? NSNumber {
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = numberValue.doubleValue
            guard doubleValue.isFinite, floor(doubleValue) == doubleValue else {
                return nil
            }
            return Int(exactly: doubleValue)
        }

        if let intValue = raw as? Int {
            return intValue
        }

        if let stringValue = raw as? String {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    func v2PanelType(_ params: [String: Any], _ key: String) -> PanelType? {
        guard let s = v2String(params, key) else { return nil }
        let normalized = s.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        return PanelType(rawValue: normalized)
    }
}
