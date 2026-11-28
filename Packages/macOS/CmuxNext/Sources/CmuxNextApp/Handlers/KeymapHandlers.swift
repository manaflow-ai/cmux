import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextSettings

/// Base Keymap… (`settings base-keymap`): switches cmux.json's shortcuts to
/// a preset (cmux, iTerm2, Terminal.app, tmux with its `ctrl+b` chords), as
/// the old app's Base Keymap picker did. A sheet lists what changes and the
/// shortcuts set by hand that stay; nothing is written until Apply.
enum KeymapHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.shortcutKeymap", run: { invocation in
            let settings = try SettingsHandlers.requireSettings(context)
            guard let preset = invocation["keymap"]?.stringValue.flatMap(ShortcutKeymapPreset.init(rawValue:)) else {
                throw ActionFailure(message: KeymapStrings.keymapRequired)
            }
            let window = context.activeWindow?.window
            Task { // task-owner: one preview, ended by its sheet
                do {
                    let plan = try await settings.keymapPlan(preset)
                    confirm(plan, registry: registry, in: window) {
                        Task { // task-owner: one write, then the watcher applies it
                            do { try await settings.apply(plan) } catch { registry.refuse(String(describing: error)) }
                        }
                    }
                } catch {
                    registry.refuse(String(describing: error))
                }
            }
        })
    }

    /// The preview as a cmux dialog on the window, else app-wide (never an
    /// app-modal run loop). An empty plan only reports.
    private static func confirm(_ plan: ShortcutKeymapPlan, registry: ActionRegistry, in window: NSWindow?, apply: @escaping () -> Void) {
        let buttons: [CmuxDialogButton] = plan.isEmpty
            ? [.ok(KeymapStrings.ok)]
            : [.cancel(KeymapStrings.cancel), CmuxDialogButton(id: "apply", title: KeymapStrings.apply, role: .default)]
        let spec = CmuxDialogSpec(title: KeymapStrings.title(presetName(plan.preset, registry)),
                                  lines: summary(plan, registry: registry), buttons: buttons, identifier: "cmux.dialog.keymap")
        let scope: CmuxDialogScope = (window ?? NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app
        CmuxDialogCenter.shared.present(spec, in: scope) { answer in
            if answer.button == "apply" { apply() }
        }
    }

    /// One line per change (`New Tab: ⌘N → ⌃B C`), then one per binding
    /// kept, as the old app's preview read.
    static func summary(_ plan: ShortcutKeymapPlan, registry: ActionRegistry) -> [String] {
        guard !plan.isEmpty || !plan.kept.isEmpty else { return [KeymapStrings.noChanges] }
        var lines: [String] = []
        if plan.preset == .iTerm2, plan.changes.contains(where: { $0.actionID == "selectSurfaceByNumber" }) {
            lines.append(KeymapStrings.iTerm2Numbers)
        }
        for change in plan.changes {
            let id = ActionID(rawValue: change.actionID)
            lines.append(KeymapStrings.change(title(id, registry), registry.shortcutDisplay(for: id) ?? KeymapStrings.none,
                                              display(change.write, for: id, registry)))
        }
        lines += plan.kept.map { KeymapStrings.kept(title(ActionID(rawValue: $0), registry)) }
        return lines
    }

    /// The shortcut a written value gives `id`; nil (an override removed)
    /// gives the catalog default.
    private static func display(_ value: JSONValue?, for id: ActionID, _ registry: ActionRegistry) -> String {
        guard let value else {
            return registry.descriptor(for: id)?.defaultShortcut.map { registry.shortcutDisplay($0, for: id) } ?? KeymapStrings.none
        }
        switch ShortcutBindingFormat.parse(value) {
        case .stroke(let stroke)?:
            return registry.shortcutDisplay(SettingsApplier.shortcut(for: stroke), for: id)
        case .chord(let first, let second)?:
            let chord = ShortcutChord(SettingsApplier.shortcut(for: first), SettingsApplier.shortcut(for: second))
            return registry.shortcutDisplay(chord, for: id)
        case .unbound?, nil:
            return KeymapStrings.none
        }
    }

    private static func title(_ id: ActionID, _ registry: ActionRegistry) -> String {
        registry.descriptor(for: id)?.title.trimmingCharacters(in: CharacterSet(charactersIn: "…")) ?? id.rawValue
    }

    /// The preset's title from the action's `keymap` choices.
    private static func presetName(_ preset: ShortcutKeymapPreset, _ registry: ActionRegistry) -> String {
        guard case .enumeration(let cases)? = registry.descriptor(for: "palette.shortcutKeymap")?.arguments.first?.kind,
              let match = cases.first(where: { $0.value == preset.rawValue }) else { return preset.rawValue }
        return match.title
    }
}

enum KeymapStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Keymap", bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    static func title(_ preset: String) -> String { format("keymap.title", "Base Keymap: %@", preset) }
    static var apply: String { text("keymap.apply", "Apply Keymap") }
    static var cancel: String { text("keymap.cancel", "Cancel") }
    static var ok: String { text("keymap.ok", "OK") }
    static var none: String { text("keymap.none", "None") }
    static var noChanges: String { text("keymap.summary.none", "No shortcuts changed.") }
    static var iTerm2Numbers: String {
        text("keymap.summary.iterm2Numbers", "⌘1…9 will select tabs in the focused pane instead of workspaces. Workspaces move to ⌥⌘1…9.")
    }
    static var keymapRequired: String { text("keymap.required", "a keymap argument (cmux, iterm2, terminal or tmux) is required") }
    static func change(_ action: String, _ before: String, _ after: String) -> String {
        format("keymap.summary.change", "%1$@: %2$@ → %3$@", action, before, after)
    }
    static func kept(_ action: String) -> String { format("keymap.summary.kept", "Kept your own shortcut for %@.", action) }
}
