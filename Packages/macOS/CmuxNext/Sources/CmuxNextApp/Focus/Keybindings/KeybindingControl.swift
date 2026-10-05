import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings

/// Socket methods for the binding table's read ops (R59): `keybinding.list`,
/// `keybinding.resolve` (`{"keys": "ctrl+k s", "window"?}`) and
/// `context.keys` (`{"window"?}`). A window is named by its id; the default
/// is the key cmux window, else the first one. The CLI and MCP verbs call
/// these methods.
enum KeybindingControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor("keybinding.list") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(KeybindingReports.list(call.params, registry: services.registry))
            },
            .mainActor("keybinding.resolve") { [weak services] call in
                guard let services else { return .value(.null) }
                guard let keys = call.params["keys"]?.stringValue ?? call.params["key"]?.stringValue else {
                    throw ControlError.invalidParams(KeybindingStrings.missingKeys)
                }
                let (context, window) = try Self.context(call.params, services: services)
                guard let report = KeybindingReports.resolve(keys, context: context, registry: services.registry, window: window) else {
                    throw ControlError.invalidParams(KeybindingStrings.invalidKeys(keys))
                }
                return .value(report)
            },
            .mainActor("context.keys") { [weak services] call in
                guard let services else { return .value(.null) }
                let (context, window) = try Self.context(call.params, services: services)
                return .value(KeybindingReports.contextKeys(context, window: window))
            },
        ]
    }

    /// The context keys of the window `params` names (or the key window).
    @MainActor
    static func context(_ params: [String: JSONValue], services: AppServices) throws -> (KeyContext, String?) {
        let controllers = services.windows.controllers
        let controller: WindowController?
        if let id = params["window"]?.stringValue {
            controller = controllers.first { $0.state.id == id }
            guard controller != nil else { throw ControlError(code: "not_found", message: KeybindingStrings.noWindow(id)) }
        } else {
            controller = controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first
        }
        guard let controller, let window = controller.window, let router = services.keyRouter else {
            return (KeyContext(bits: services.registry.context), nil)
        }
        return (router.keyContext(for: controller.focus.state, facts: router.facts(in: window, controller: controller)), controller.state.id)
    }
}

/// Errors of the keybinding ops (Keybindings.xcstrings).
enum KeybindingStrings {
    static var pageTitle: String {
        String(localized: "keybinding.page.title", defaultValue: "Keyboard Shortcuts", table: "Keybindings", bundle: .module)
    }

    static var editingUnsupported: String {
        String(localized: "keybinding.error.editingUnsupported",
               defaultValue: "Editing key bindings needs keybindings.json support, which is not ready yet.",
               table: "Keybindings", bundle: .module)
    }

    static var missingKeys: String {
        String(localized: "keybinding.error.missingKeys", defaultValue: "keybinding.resolve requires params.keys (for example \"ctrl+k s\").",
               table: "Keybindings", bundle: .module)
    }

    static func invalidKeys(_ keys: String) -> String {
        String(format: String(localized: "keybinding.error.invalidKeys", defaultValue: "These keys do not parse: %@",
                              table: "Keybindings", bundle: .module), keys)
    }

    static func noWindow(_ id: String) -> String {
        String(format: String(localized: "keybinding.error.noWindow", defaultValue: "No window has the id %@.",
                              table: "Keybindings", bundle: .module), id)
    }
}
