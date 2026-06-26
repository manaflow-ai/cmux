import CmuxControlSocket
import CmuxPanes
import Foundation
import Bonsplit

extension TerminalController {
    /// The lifted `[String: Any]`-lane param decoders, owned by
    /// `CmuxControlSocket`. Stateless value type, so a fresh instance per read
    /// is equivalent to a stored one; the v2* helpers below forward to it so
    /// every call site stays byte-identical.
    nonisolated var v2AnyParamReader: ControlAnyParamReader { ControlAnyParamReader() }

    nonisolated func v2String(_ params: [String: Any], _ key: String) -> String? {
        v2AnyParamReader.string(params, key)
    }

    nonisolated func v2StringArray(_ params: [String: Any], _ key: String) -> [String]? {
        v2AnyParamReader.stringArray(params, key)
    }

    nonisolated func v2StringMap(_ params: [String: Any], _ key: String) -> [String: String]? {
        v2AnyParamReader.stringMap(params, key)
    }

    nonisolated func v2TrimmedStringMap(_ params: [String: Any], keys: [String]) -> [String: String] {
        v2AnyParamReader.trimmedStringMap(params, keys: keys)
    }

    nonisolated func v2ActionKey(_ params: [String: Any], _ key: String = "action") -> String? {
        v2AnyParamReader.actionKey(params, key)
    }

    nonisolated func v2RawString(_ params: [String: Any], _ key: String) -> String? {
        v2AnyParamReader.rawString(params, key)
    }

    nonisolated func v2OptionalTrimmedRawString(_ params: [String: Any], _ key: String) -> String? {
        v2AnyParamReader.optionalTrimmedRawString(params, key)
    }

    nonisolated func v2InitialDividerPosition(_ params: [String: Any]) -> (value: Double?, error: V2CallResult?) {
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

    nonisolated func v2UUID(_ params: [String: Any], _ key: String) -> UUID? {
        guard let s = v2String(params, key) else { return nil }
        if let uuid = UUID(uuidString: s) {
            return uuid
        }
        return v2MainSync { controlCommandCoordinator.resolveRef(s) }
    }

    func v2UUIDAny(_ raw: Any?) -> UUID? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid
        }
        return controlCommandCoordinator.resolveRef(trimmed)
    }

    nonisolated func v2Bool(_ params: [String: Any], _ key: String) -> Bool? {
        v2AnyParamReader.bool(params, key)
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

    nonisolated func v2Int(_ params: [String: Any], _ key: String) -> Int? {
        v2AnyParamReader.int(params, key)
    }

    nonisolated func v2Double(_ params: [String: Any], _ key: String) -> Double? {
        v2AnyParamReader.double(params, key)
    }

    nonisolated func v2HasNonNullParam(_ params: [String: Any], _ key: String) -> Bool {
        v2AnyParamReader.hasNonNullParam(params, key)
    }

    nonisolated func v2StrictInt(_ params: [String: Any], _ key: String) -> Int? {
        v2AnyParamReader.strictInt(params, key)
    }

    nonisolated func v2StrictIntAny(_ raw: Any?) -> Int? {
        v2AnyParamReader.strictIntAny(raw)
    }

    nonisolated func v2PanelType(_ params: [String: Any], _ key: String) -> PanelType? {
        guard let s = v2String(params, key) else { return nil }
        switch v2NormalizedToken(s) {
        case "terminal":
            return .terminal
        case "browser":
            return .browser
        case "markdown":
            return .markdown
        case "filepreview":
            return .filePreview
        case "rightsidebartool":
            return .rightSidebarTool
        case "agentsession":
            return .agentSession
        default:
            return nil
        }
    }

    nonisolated func v2NormalizedToken(_ raw: String) -> String {
        v2AnyParamReader.normalizedToken(raw)
    }
}
