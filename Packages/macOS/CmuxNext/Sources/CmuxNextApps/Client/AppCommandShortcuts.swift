public import AppKit
public import CmuxNextActions

/// The key chords of extensions' commands (`shortcuts` in `apps-list`, `apps/shortcuts.rs`), as
/// actions in the app's registry: each command with a chord is the action `app:<app id>#<op>`
/// with the catalog's first chord as its default shortcut, so the binding table routes it like a
/// built-in one and Settings > Keyboard rebinds it. The
/// actions follow the apps: a command that goes away (an app removed, hidden or turned off) is
/// unbound.
@MainActor
public final class AppCommandShortcuts {
    /// One command that has a chord, as the palette reaches it.
    public struct Entry: Equatable, Sendable {
        public var app: String
        public var appName: String
        public var command: AppRecord.Command

        public init(app: String, appName: String, command: AppRecord.Command) {
            self.app = app
            self.appName = appName
            self.command = command
        }
    }

    private let registry: ActionRegistry
    private let run: @MainActor (_ app: String, _ op: String) -> Void
    private var registered: [ActionID: Entry] = [:]

    /// - Parameters:
    ///   - registry: The app's action registry.
    ///   - run: Runs one command as the person's (the palette's run path).
    public init(registry: ActionRegistry, run: @escaping @MainActor (_ app: String, _ op: String) -> Void) {
        self.registry = registry
        self.run = run
    }

    /// The action id of an extension's command.
    public static func actionID(app: String, op: String) -> ActionID { ActionID(rawValue: "app:\(app)#\(op)") }

    /// The registry's shortcut for a daemon chord; nil for a modifier name it does not know.
    public static func shortcut(_ chord: AppRecord.Command.Chord) -> Shortcut? {
        var modifiers: NSEvent.ModifierFlags = []
        for name in chord.modifiers {
            switch name {
            case "cmd": modifiers.insert(.command)
            case "ctrl": modifiers.insert(.control)
            case "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard chord.key.count == 1, !modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        return Shortcut(chord.key, modifiers: modifiers)
    }

    /// Makes the registry's extension actions exactly `entries`' commands that have a chord.
    public func apply(_ entries: [Entry]) {
        var next: [ActionID: Entry] = [:]
        for entry in entries where entry.command.shortcuts.contains(where: { Self.shortcut($0) != nil }) {
            next[Self.actionID(app: entry.app, op: entry.command.op)] = entry
        }
        guard next != registered else { return }
        for id in registered.keys where next[id] == nil { registry.unbind(id) }
        for (id, entry) in next where registered[id] != entry {
            let run = run
            registry.register(Action(
                id: id,
                title: entry.command.title.resolved(),
                keywords: [entry.appName, entry.app, entry.command.op],
                shortcut: entry.command.shortcuts.lazy.compactMap(Self.shortcut).first,
                handler: { run(entry.app, entry.command.op) }
            ))
        }
        registered = next
    }
}
