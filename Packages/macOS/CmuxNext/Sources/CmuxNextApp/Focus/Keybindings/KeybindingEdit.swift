import CmuxNextPages
import CmuxNextSettings

/// One edit of the binding table, the same from the Keyboard Shortcuts page
/// (`cmux.keybindings.set`, `remove`, `reset`) and from the control socket
/// (`keybinding.set`, `remove`, `reset`; cx-9ce.26, R33: an agent or a
/// script changes a binding as the user does). ``KeybindingPageWrites``
/// writes it; then every open page re-lists.
enum KeybindingEdit {
    case set, remove, reset

    /// Runs the edit with `params` (``KeybindingPageWrites``'s shapes); its
    /// refusals are `PageError`s.
    @MainActor
    func run(_ params: [String: JSONValue], services: AppServices) async throws {
        guard let settings = services.settings else {
            throw PageError(code: "cmux.keybindings.unsupported", message: KeybindingStrings.editingUnsupported)
        }
        var writes = KeybindingPageWrites(registry: services.registry, settings: settings, file: services.keybindingsFile)
        writes.keepsBoth = params["keep_both"]?.boolValue == true
        switch self {
        case .set: try await writes.set(params)
        case .remove: try await writes.remove(params)
        case .reset: try await writes.reset(params)
        }
        services.keybindingsFile.edited()
    }
}
