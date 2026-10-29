import CmuxNextDesign
import Foundation

/// Strict decoding for the page's declarative native tab-row controls.
nonisolated enum AgentPaneTabRowTools {
    nonisolated static let maximumTools = 16
    nonisolated static let maximumMenuItems = 32
    nonisolated static let maximumDepth = 2
    nonisolated static let maximumText = 64

    nonisolated static func list(_ raw: Any?) -> [PaneTabRowTool]? {
        guard let raw = raw as? [Any], raw.count <= maximumTools else { return nil }
        var tools: [PaneTabRowTool] = []
        tools.reserveCapacity(raw.count)
        for value in raw {
            guard let parsed = tool(value) else { return nil }
            tools.append(parsed)
        }
        return tools
    }

    private nonisolated static func tool(_ raw: Any) -> PaneTabRowTool? {
        guard let object = raw as? [String: Any],
              let id = text(object["id"]), let symbol = text(object["symbol"]), let label = text(object["label"]),
              object["enabled"] is Bool, object["toggled"] is Bool,
              let enabled = object["enabled"] as? Bool, let toggled = object["toggled"] as? Bool,
              let menu = menu(object["menu"], depth: 0) else { return nil }
        let badge: String?
        if let rawBadge = object["badge"], !(rawBadge is NSNull) {
            guard let parsed = optionalText(rawBadge) else { return nil }
            badge = parsed
        } else {
            badge = nil
        }
        return PaneTabRowTool(id: id, symbol: symbol, label: label, enabled: enabled, toggled: toggled,
                              badge: badge, menu: menu)
    }

    private nonisolated static func menu(_ raw: Any?, depth: Int) -> [PaneTabRowMenuItem]? {
        guard let raw else { return [] }
        guard depth <= maximumDepth, let list = raw as? [Any], list.count <= maximumMenuItems else { return nil }
        let rows = list.compactMap { item($0, depth: depth) }
        return rows.count == list.count ? rows : nil
    }

    private nonisolated static func item(_ raw: Any, depth: Int) -> PaneTabRowMenuItem? {
        guard let object = raw as? [String: Any], let id = text(object["id"]), let label = text(object["label"]),
              object["enabled"] is Bool, let enabled = object["enabled"] as? Bool,
              let children = menu(object["children"], depth: depth + 1) else { return nil }
        let checked: Bool?
        if let rawChecked = object["checked"], !(rawChecked is NSNull) {
            guard let parsed = optionalBool(rawChecked) else { return nil }
            checked = parsed
        } else {
            checked = nil
        }
        let role: String?
        if let rawRole = object["role"], !(rawRole is NSNull) {
            guard let parsed = optionalRole(rawRole) else { return nil }
            role = parsed
        } else {
            role = nil
        }
        return PaneTabRowMenuItem(id: id, label: label, enabled: enabled, checked: checked, role: role, children: children)
    }

    private nonisolated static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= maximumText else { return nil }
        return value
    }

    private nonisolated static func optionalText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return text(value)
    }

    private nonisolated static func optionalBool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? Bool
    }

    private nonisolated static func optionalRole(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let value = value as? String, value == "destructive" else { return nil }
        return value
    }
}
