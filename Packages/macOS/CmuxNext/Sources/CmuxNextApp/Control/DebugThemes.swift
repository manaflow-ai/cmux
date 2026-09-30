import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSettings

/// `debug.themes`: per window its room scope, per mounted workspace its
/// workspace scope, per live terminal its scope and the Ghostty theme its
/// surface uses (plans/cmux-next/data-model.md 6). Colors are the scope's
/// resolved window and content backgrounds as `#RRGGBB`.
enum DebugThemes {
    static func report(services: AppServices) -> JSONValue {
        let windows = (services.windows?.controllers ?? []).map { controller -> JSONValue in
            var object = scope(controller.themeScope)
            object["window_number"] = .number(Double(controller.window?.windowNumber ?? 0))
            object["room"] = .string(controller.state.profileID.rawValue)
            object["appearance"] = .string(controller.window?.appearance?.name.rawValue ?? "")
            object["workspaces"] = .array(controller.mountedContents.map { content in
                var workspace = scope(content.themeScope)
                workspace["workspace"] = .string(content.workspace.id)
                workspace["shown"] = .bool(content === controller.content)
                return .object(workspace)
            })
            return .object(object)
        }
        let terminals = (services.cache?.terminals ?? [:]).sorted { $0.key < $1.key }.map { key, entry -> JSONValue in
            var object = scope(entry.themeScope)
            object["tab"] = .string(key)
            object["surface_theme"] = entry.session.theme.map { .string($0.themeName) } ?? .null
            object["badge"] = services.themes.badge(forTerminal: entry.themeKey).map { .string($0.name) } ?? .null
            return .object(object)
        }
        return .object(["windows": .array(windows), "terminals": .array(terminals)])
    }

    private static func scope(_ scope: ThemeScope) -> [String: JSONValue] {
        [
            "spec": scope.spec.map { .string($0.raw) } ?? .null,
            "effective_spec": scope.effectiveSpec.map { .string($0.raw) } ?? .null,
            "source": .string(String(describing: scope.source)),
            "window_background": .string(hex(scope.tokens.windowBackground)),
            "text_primary": .string(hex(scope.tokens.textPrimary)),
            "is_dark": .bool(scope.tokens.isDark),
        ]
    }

    private static func hex(_ rgb: ThemeRGB) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.red), byte(rgb.green), byte(rgb.blue))
    }
}
