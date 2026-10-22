import CmuxNextActions
import CmuxNextDaemon

/// The config scripts' key modes (`cmux.keys.mode`, scripting-runtime.md
/// section 10.3). Each mode gets the action `keyMode.enter.<name>`; while it
/// is on, context key `keyMode` names it, its own bindings
/// (`cmux.keys.bind(key, target, {mode})`) run first and may be bare keys
/// (`h`, `shift+l`) in any focus but a text field, Escape ends it
/// (`keyMode.exit`) unless the mode binds Escape, and an exclusive mode
/// swallows the other keys without Command, Control or Option. The mode
/// is app-wide, like tmux's key tables.
@MainActor
final class ScriptKeyModes {
    weak var registry: ActionRegistry?
    private(set) var modes: [String: ScriptConfigReport.Mode] = [:]
    /// Each mode's bindings, their commands checked (``ScriptConfigController``).
    var bindings: [String: [KeyBinding]] = [:]
    /// The mode that is on.
    private(set) var active: String?

    static let exitID: ActionID = "keyMode.exit"
    static func enterID(_ mode: String) -> ActionID { ActionID(rawValue: "keyMode.enter.\(mode)") }

    var isExclusive: Bool { active.flatMap { modes[$0]?.exclusive } ?? false }

    /// Registers the enter actions of `modes` and the exit action; returns
    /// their ids. A mode that is gone ends.
    func load(_ modes: [ScriptConfigReport.Mode]) -> [ActionID] {
        self.modes = Dictionary(modes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        if let active, self.modes[active] == nil { self.active = nil }
        guard let registry, !modes.isEmpty else { return [] }
        var ids: [ActionID] = []
        for mode in modes {
            let name = mode.name
            registry.register(Action(id: Self.enterID(name), title: ScriptConfigStrings.enterMode(mode.title),
                                     keywords: ["mode", "keys", name], handler: { [weak self] in self?.enter(name) }))
            ids.append(Self.enterID(name))
        }
        registry.register(Action(id: Self.exitID, title: ScriptConfigStrings.exitMode, keywords: ["mode", "keys", "escape"],
                                 handler: { [weak self] in self?.exit() }))
        ids.append(Self.exitID)
        return ids
    }

    func enter(_ mode: String) {
        guard modes[mode] != nil else { return }
        active = mode
    }

    func exit() {
        active = nil
    }

    /// The active mode's binding that `readings` (one key's readings) completes where `context` holds.
    func binding(for readings: [Shortcut], in context: KeyContext) -> KeyBinding? {
        guard let active else { return nil }
        for reading in readings {
            if let hit = bindings[active]?.first(where: { $0.keys == [reading] && ($0.when?.evaluate(context) ?? true) }) { return hit }
        }
        return nil
    }
}
