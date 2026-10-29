import CmuxNextDesign
import Foundation

/// Strict decoding for the page's declarative native tab-row controls.
enum AgentPaneTabRowTools {
    static let maximumTools = 16
    static let maximumMenuItems = 32
    static let maximumDepth = 2
    static let maximumText = 64

    static func list(_ raw: Any?) -> [PaneTabRowTool]? {
        guard let raw = raw as? [Any], raw.count <= maximumTools else { return nil }
        var tools: [PaneTabRowTool] = []
        tools.reserveCapacity(raw.count)
        for value in raw {
            guard let parsed = tool(value) else { return nil }
            tools.append(parsed)
        }
        return tools
    }

    private static func tool(_ raw: Any) -> PaneTabRowTool? {
        guard let object = raw as? [String: Any],
              let id = text(object["id"]), let symbol = text(object["symbol"]), let label = text(object["label"]),
              object["enabled"] is Bool, object["toggled"] is Bool,
              let enabled = object["enabled"] as? Bool, let toggled = object["toggled"] as? Bool,
              let badge = optionalText(object["badge"]),
              let menu = menu(object["menu"], depth: 0) else { return nil }
        return PaneTabRowTool(id: id, symbol: symbol, label: label, enabled: enabled, toggled: toggled,
                              badge: badge, menu: menu)
    }

    private static func menu(_ raw: Any?, depth: Int) -> [PaneTabRowMenuItem]? {
        guard let raw else { return [] }
        guard depth <= maximumDepth, let list = raw as? [Any], list.count <= maximumMenuItems else { return nil }
        let rows = list.compactMap { item($0, depth: depth) }
        return rows.count == list.count ? rows : nil
    }

    private static func item(_ raw: Any, depth: Int) -> PaneTabRowMenuItem? {
        guard let object = raw as? [String: Any], let id = text(object["id"]), let label = text(object["label"]),
              object["enabled"] is Bool, let enabled = object["enabled"] as? Bool,
              let checked = optionalBool(object["checked"]), let role = optionalRole(object["role"]),
              let children = menu(object["children"], depth: depth + 1) else { return nil }
        return PaneTabRowMenuItem(id: id, label: label, enabled: enabled, checked: checked, role: role, children: children)
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= maximumText else { return nil }
        return value
    }

    private static func optionalText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return text(value)
    }

    private static func optionalBool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? Bool
    }

    private static func optionalRole(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let value = value as? String, value == "destructive" else { return nil }
        return value
    }
}
