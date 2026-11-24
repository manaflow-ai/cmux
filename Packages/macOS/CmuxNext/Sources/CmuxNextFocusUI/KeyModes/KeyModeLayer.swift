public import AppKit
public import CmuxNextActions

/// User key modes (row key-modes, design/key-modes.md): `keyMode.enter` with a `name` turns a mode
/// on; while it is on, the `keyMode` context key names it, so keybindings.json entries under
/// `keyMode == 'name'` may use bare keys (`h`, `j`, `g g`). The key router (`routesBareKey`) gives
/// them the key in any focus but a text field, a terminal included: the mode is a layer over it.
/// Escape ends the mode unless the mode binds Escape; `keyMode.exit` ends it too. A bare key the
/// mode does not bind is swallowed: typing into the page under the layer is what Escape gets back.
public final class KeyModeLayer {
    /// The mode that is on, nil outside one. One at a time: entering another ends the first.
    public private(set) var name: String?
    /// Names the mode and lists its keys; not the router's which-key, which every chord step hides.
    private let indicator = WhichKeyController()
    private weak var registry: ActionRegistry?

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    public var isOn: Bool { name != nil }

    /// Binds `keyMode.enter` (refused without a name) and `keyMode.exit` (unavailable outside a mode).
    public func bind(into registry: ActionRegistry) {
        registry.bindEffect("keyMode.enter", effect: { [weak self] invocation in
            let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return .refused(Self.noNameRefusal) }
            self?.enter(name)
            return .done
        })
        registry.bindEffect("keyMode.exit", unavailable: { [weak self] in
            self?.isOn == true ? nil : Self.notInModeRefusal
        }, effect: { [weak self] _ in
            self?.exit()
            return .done
        })
    }

    /// Turns on the mode `name` (another mode ends) and names it at the bottom of `window`.
    public func enter(_ name: String, in window: NSWindow? = NSApp.keyWindow) {
        self.name = name
        showIndicator(in: window)
    }

    /// Ends the mode, if one is on.
    public func exit() {
        guard isOn else { return }
        name = nil
        indicator.hide()
    }

    /// `context` with the `keyMode` key naming the mode that is on.
    public func marking(_ context: KeyContext) -> KeyContext {
        guard let name else { return context }
        var context = context
        context[KeyContext.keyMode] = .string(name)
        return context
    }

    /// A mode binding ran from a bare key in `window`: its indicator follows. Returns true (the key is consumed).
    public func ran(in window: NSWindow?) -> Bool {
        if isOn { showIndicator(in: window) }
        return true
    }

    /// A bare key no binding took: outside a mode it goes on (false). In one it is consumed (`consume`
    /// runs, true), and Escape ends the mode.
    public func unbound(keyCode: UInt16, consume: () -> Void) -> Bool {
        guard isOn else { return false }
        consume()
        if keyCode == Self.escapeKeyCode { exit() }
        return true
    }

    public nonisolated static let escapeKeyCode: UInt16 = 53

    private func showIndicator(in window: NSWindow?) {
        guard let name, let registry, let window = window ?? NSApp.keyWindow else { return }
        let rows = Self.rows(table: RegistryKeyBindings(registry).table, context: marking(KeyContext(bits: registry.context)),
                             title: { [registry] in registry.title(for: $0) ?? $0.rawValue })
        indicator.show(title: name, rows: rows, in: window)
    }

    /// The bare first keys the entries under `context`'s key mode bind, one row each (a sequence shows all its keys).
    public static func rows(table: KeyBindingTable, context: KeyContext, title: (ActionID) -> String) -> [WhichKeyRow] {
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

    static var noNameRefusal: String {
        String(localized: "keyMode.refusal.noName", defaultValue: "Name the key mode to enter.", table: "KeyModes", bundle: .localizedModule)
    }

    static var notInModeRefusal: String {
        String(localized: "keyMode.refusal.notInMode", defaultValue: "No key mode is on.", table: "KeyModes", bundle: .localizedModule)
    }
}
