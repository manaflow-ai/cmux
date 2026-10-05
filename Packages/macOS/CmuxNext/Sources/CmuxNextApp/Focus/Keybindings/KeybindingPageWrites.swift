import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings

/// `cmux.keybindings.set`, `remove` and `reset` of the Keyboard Shortcuts
/// page, written to cmux.json (`shortcuts.bindings.<id>`).
@MainActor
struct KeybindingPageWrites {
    let registry: ActionRegistry
    let settings: SettingsController

    func set(_ params: [String: JSONValue]) async throws {
        throw PageError(code: "cmux.keybindings.unsupported", message: KeybindingStrings.editingUnsupported)
    }

    func remove(_ params: [String: JSONValue]) async throws {
        throw PageError(code: "cmux.keybindings.unsupported", message: KeybindingStrings.editingUnsupported)
    }

    func reset(_ params: [String: JSONValue]) async throws {
        throw PageError(code: "cmux.keybindings.unsupported", message: KeybindingStrings.editingUnsupported)
    }
}
