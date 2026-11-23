import AppKit
import CmuxNextActions

/// User key modes (row key-modes, design/key-modes.md): Enter Key Mode… turns on the mode its
/// `name` names, so keybindings.json entries under `keyMode == 'name'` take bare keys
/// (KeyRouter+KeyModes); Exit Key Mode ends it, as Escape does when the mode does not bind it.
enum KeyModeHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("keyMode.enter", invoke: { [weak services, weak registry] invocation in
            guard let services else { return }
            let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                registry?.refuse(KeyModeStrings.noName)
                return
            }
            services.keyRouter.enterKeyMode(name, in: services.windows.active?.window ?? NSApp.keyWindow)
        })
        registry.bind("keyMode.exit", unavailable: { [weak services] in
            services?.keyRouter.keyMode == nil ? KeyModeStrings.notInMode : nil
        }, invoke: { [weak services] _ in
            services?.keyRouter.exitKeyMode()
        })
    }
}

enum KeyModeStrings {
    static var noName: String {
        String(localized: "keyMode.refusal.noName", defaultValue: "Name the key mode to enter.", table: "KeyModes", bundle: .module.inAppLanguage)
    }

    static var notInMode: String {
        String(localized: "keyMode.refusal.notInMode", defaultValue: "No key mode is on.", table: "KeyModes", bundle: .module.inAppLanguage)
    }
}
