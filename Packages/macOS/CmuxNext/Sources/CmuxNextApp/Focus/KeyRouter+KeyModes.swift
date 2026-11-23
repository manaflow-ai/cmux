import AppKit
import CmuxNextActions
import CmuxNextFocusUI

// User key modes (row key-modes, design/key-modes.md): `keyMode.enter` with a `name` turns a mode
// on; while it is on, the `keyMode` context key names it, so keybindings.json entries under
// `keyMode == 'name'` may use bare keys (`h`, `j`, `g g`). They take the key in any focus but a
// text field (a terminal included: the mode is a layer over it). Escape ends the mode unless the
// mode binds Escape; `keyMode.exit` ends it too. A bare key the mode does not bind is swallowed:
// a mode is a layer, and typing into the page under it is what Escape gets back.
extension KeyRouter {
    /// Turns on the user key mode `name` (another mode ends) and names it at the bottom of the key window.
    func enterKeyMode(_ name: String, in window: NSWindow?) {
        cancelChord()
        keyMode = name
        showKeyModeIndicator(in: window)
    }

    /// Ends the user key mode, if one is on.
    func exitKeyMode() {
        guard keyMode != nil else { return }
        keyMode = nil
        chords.cancel()
        keyModeIndicator.hide()
    }

    /// A bare key-down while a user key mode is on: its binding (or a sequence step) runs; Escape
    /// with no binding ends the mode; any other bare key is swallowed. A text field keeps typing.
    /// Returns whether the key was consumed.
    func routesKeyModeKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard keyMode != nil, Self.isBareKey(event.modifierFlags), let window else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return false }
        let facts = facts(in: window, controller: controller)
        if Self.belongsToInputMethod(event, facts: facts) { return false }
        let context = keyContext(for: controller.focus.state, facts: facts)
        // A text field (native or in a page) has the keyboard: the key is typing (`KeyContext.ownsBareKeys`).
        guard context.ownsBareKeys else { return false }
        decided.add(event)
        if dispatchBare(event, in: window, controller: controller, context: context, facts: facts) {
            showKeyModeIndicator(in: controller.window ?? window)
            return true
        }
        if event.keyCode == Self.escapeKeyCode { exitKeyMode() }
        return true
    }

    nonisolated static let escapeKeyCode: UInt16 = 53

    /// The mode's name over the bare keys it binds here.
    private func showKeyModeIndicator(in window: NSWindow?) {
        guard let keyMode else { return keyModeIndicator.hide() }
        guard let window = window ?? NSApp.keyWindow else { return }
        var context = KeyContext(bits: registry.context)
        context[KeyContext.keyMode] = .string(keyMode)
        keyModeIndicator.show(title: keyMode, rows: Self.keyModeRows(table: RegistryKeyBindings(registry).table, context: context,
                                                                  title: { [registry] in registry.title(for: $0) ?? $0.rawValue }),
                              in: window)
    }

    /// The bare first keys entries under `context`'s key mode bind, one row each (a sequence shows its first key).
    nonisolated static func keyModeRows(table: KeyBindingTable, context: KeyContext, title: (ActionID) -> String) -> [WhichKeyRow] {
        var seen = Set<String>()
        return table.entries.filter { entry in
            guard let first = entry.keys.first, first.isBare, let when = entry.when else { return false }
            return when.allowsBareKeys && when.requiresKeyMode && entry.applies(in: context)
        }.compactMap { entry -> WhichKeyRow? in
            let key = entry.keys.map(\.displayString).joined(separator: " ")
            guard seen.insert(key).inserted else { return nil }
            return WhichKeyRow(key: key, title: title(entry.command), isEnabled: true)
        }.sorted { ($0.key.lowercased(), $0.title) < ($1.key.lowercased(), $1.title) }
    }
}
