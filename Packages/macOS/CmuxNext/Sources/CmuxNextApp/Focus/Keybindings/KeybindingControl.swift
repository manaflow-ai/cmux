import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings

/// Socket methods for the binding table (R59): the read ops `keybinding.list`,
/// `keybinding.resolve` (`{"keys": "ctrl+k s", "window"?}`) and
/// `context.keys` (`{"window"?}`), and the edits `keybinding.set`, `remove`
/// and `reset` (cx-9ce.26), the Keyboard Shortcuts page's own write
/// (``KeybindingEdit``) with its params; each answers the action's rows as
/// `keybinding.list` lists them. A window is named by its id; the default
/// is the key cmux window, else the first one. The CLI and MCP verbs call
/// these methods.
enum KeybindingControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        let edits: [(String, KeybindingEdit)] = [("keybinding.set", .set), ("keybinding.remove", .remove), ("keybinding.reset", .reset)]
        return edits.map { name, edit in
            ControlMethod.mainActor(name) { [weak services] call in
                guard let services else { return .value(.null) }
                let params = call.params
                return .followUp { try await Self.run(edit, params, services: services) }
            }
        } + [
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

    /// Runs `edit`; the page's refusals answer as the socket's: unparsable keys, an unknown
    /// action or a bad `when` are `invalid_params`, the rest (the recorder's refusals, a
    /// conflict in the same place, a Ghostty row) `unavailable`, with the page's code as `reason`.
    @MainActor
    static func run(_ edit: KeybindingEdit, _ params: [String: JSONValue], services: AppServices) async throws -> JSONValue {
        do {
            try await edit.run(params, services: services)
        } catch let error as PageError {
            let code = error.code == "cmux.keybindings.invalid" ? "invalid_params" : "unavailable"
            throw ControlError(code: code, message: error.message, data: ["reason": .string(error.code)])
        }
        return KeybindingReports.list(["command": params["command"] ?? .null], registry: services.registry)
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
        guard let controller, let window = controller.window, case let router = services.keyRouter else {
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

    static var needsKeybindingsJSON: String {
        String(localized: "keybinding.error.needsKeybindingsJSON",
               defaultValue: "cmux.json holds one shortcut per action, with no When clause or arguments. This change needs keybindings.json, which is not ready yet.",
               table: "Keybindings", bundle: .module)
    }

    static var familyNeedsDigit: String {
        String(localized: "keybinding.error.familyNeedsDigit",
               defaultValue: "A numbered shortcut takes a digit: press 1 with the modifiers you want.",
               table: "Keybindings", bundle: .module)
    }

    static var ghosttyReadOnly: String {
        String(localized: "keybinding.error.ghosttyReadOnly", defaultValue: "This shortcut comes from your Ghostty config. Change it there.",
               table: "Keybindings", bundle: .module)
    }

    static var atMostTwoKeys: String {
        String(localized: "keybinding.error.atMostTwoKeys", defaultValue: "cmux.json holds shortcuts of one key or a two-key chord.",
               table: "Keybindings", bundle: .module)
    }

    static func unknownCommand(_ id: String) -> String {
        String(format: String(localized: "keybinding.error.unknownCommand", defaultValue: "No action has the id %@.",
                              table: "Keybindings", bundle: .module), id)
    }

    static func noWindow(_ id: String) -> String {
        String(format: String(localized: "keybinding.error.noWindow", defaultValue: "No window has the id %@.",
                              table: "Keybindings", bundle: .module), id)
    }
}
