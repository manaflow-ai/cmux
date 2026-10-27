import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextSettings
import CmuxNextWakeups

/// Base Keymap… (`settings base-keymap`): switches cmux.json's shortcuts to
/// a preset (cmux, iTerm2, Terminal.app, tmux with its `ctrl+b` chords), as
/// the old app's Base Keymap picker did. It applies at once (Lawrence
/// 2026-10-07: no confirm dialogs) and a toast in the window offers Undo,
/// which puts back every shortcut it changed. Shortcuts set by hand stay.
enum KeymapHandlers {
    static let toastID = "keymap-applied"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.shortcutKeymap", run: { invocation in
            let settings = try SettingsHandlers.requireSettings(context)
            guard let preset = invocation["keymap"]?.stringValue.flatMap(ShortcutKeymapPreset.init(rawValue:)) else {
                throw ActionFailure(message: KeymapStrings.keymapRequired)
            }
            let window = context.activeWindow?.window
            let user = invocation.origin == .user
            let mainWork = context.services.mainWork, end = registry.completion(on: mainWork)
            // One write off main, then the watcher applies it; the toast (a person's run) or the refusal is the run's
            // completion on main (userBlocking for the person, automation for the CLI).
            end.start {
                do {
                    let plan = try await settings.keymapPlan(preset)
                    let undo = try await settings.applyUndoably(plan)
                    guard user else { return }
                    end.post(owner: "KeymapHandlers.toast", answering: true) {
                        toast(plan, registry: registry, in: window) {
                            restore(undo, settings: settings, registry: registry, mainWork: mainWork)
                        }
                    }
                } catch {
                    let reason = String(describing: error)
                    end.post(owner: "KeymapHandlers.refuse", answering: true) { registry.refuse(reason) }
                }
            }
        })
    }

    /// The toast's Undo (the person's click): one write back off main; a failure is refused in the click's completion.
    private static func restore(_ undo: ShortcutKeymapUndo, settings: SettingsController, registry: ActionRegistry,
                                mainWork: MainWorkScheduler) {
        let end = registry.completion(on: mainWork)
        end.start {
            do {
                try await settings.restore(undo)
            } catch {
                let reason = String(describing: error)
                end.post(owner: "KeymapHandlers.refuse", answering: true) { registry.refuse(reason) }
            }
        }
    }

    /// "Base Keymap: tmux" with Undo; an empty plan says nothing changed.
    @MainActor private static func toast(_ plan: ShortcutKeymapPlan, registry: ActionRegistry, in window: NSWindow?,
                                         undo: @escaping @MainActor () -> Void) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        var parts = [KeymapStrings.title(presetName(plan.preset, registry))]
        if plan.isEmpty { parts.append(KeymapStrings.noChanges) }
        if plan.preset == .iTerm2, plan.changes.contains(where: { $0.actionID == "selectSurfaceByNumber" }) {
            parts.append(KeymapStrings.iTerm2Numbers)
        }
        let toast = CmuxToast(id: toastID, message: parts.joined(separator: " "), action: plan.isEmpty ? nil : .undo(),
                              duration: .seconds(plan.isEmpty ? 6 : 10))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = undo
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
    static var noChanges: String { text("keymap.summary.none", "No shortcuts changed.") }
    static var iTerm2Numbers: String {
        text("keymap.summary.iterm2Numbers", "⌘1…9 will select tabs in the focused pane instead of workspaces. Workspaces move to ⌥⌘1…9.")
    }
    static var keymapRequired: String { text("keymap.required", "a keymap argument (cmux, iterm2, terminal or tmux) is required") }
}
