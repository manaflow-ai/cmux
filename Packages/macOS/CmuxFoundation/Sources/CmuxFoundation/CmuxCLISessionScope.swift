/// The CLI's session scope (`--session <name|uuid>`, alias `--machine`):
/// which federated cmux-tui session unqualified object refs, indexes, lists
/// and creation commands address (cmux-next data-model.md 1.3).
///
/// Before the command the flag is global, like `--window`. After the
/// command it is taken only by commands that target app objects, because
/// other commands (`vm`, agent hooks, `vault`) own a `--session` or
/// `--machine` option with another meaning.
public enum CmuxCLISessionScope {
    /// The flag names.
    public static let optionNames: Set<String> = ["--session", "--machine"]

    /// Commands whose `--session`/`--machine` after the command is the scope.
    public static let objectCommands: Set<String> = [
        "send", "send-key", "send-panel", "send-key-panel", "read-screen", "capture-pane", "paste", "clear-history",
        "tree", "identify", "list-workspaces", "list-panes", "list-panels", "list-pane-surfaces", "list-surfaces",
        "current-workspace", "surface-health", "new-workspace", "new-split", "new-pane", "new-surface",
        "close-surface", "close-workspace", "select-workspace", "rename-workspace", "rename-window", "rename-tab",
        "focus-pane", "focus-panel", "move-surface", "reorder-surface", "reorder-workspace", "swap-pane",
        "tab-action", "tab", "pane", "workspace", "surface", "notify",
    ]

    /// Control methods that honor a `session` param.
    public static func applies(toMethod method: String) -> Bool {
        let prefixes = ["workspace.", "surface.", "pane.", "tab.", "terminal.", "notification.", "browser."]
        return prefixes.contains { method.hasPrefix($0) } || method == "system.tree" || method == "system.identify"
    }

    /// Removes `--session`/`--machine` (and `--session=value`) from an
    /// object command's arguments. Stops at `--`. Other commands keep
    /// their arguments unchanged.
    ///
    /// - Returns: The last scope given, and the remaining arguments.
    public static func extract(command: String, arguments: [String]) -> (session: String?, remaining: [String]) {
        guard objectCommands.contains(command) else { return (nil, arguments) }
        var session: String?
        var remaining: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                remaining.append(contentsOf: arguments[index...])
                break
            }
            if optionNames.contains(argument), index + 1 < arguments.count {
                session = arguments[index + 1]
                index += 2
                continue
            }
            if let name = optionNames.first(where: { argument.hasPrefix($0 + "=") }) {
                session = String(argument.dropFirst(name.count + 1))
                index += 1
                continue
            }
            remaining.append(argument)
            index += 1
        }
        return (session.flatMap { $0.isEmpty ? nil : $0 }, remaining)
    }

    /// An `action.run` target with the scope as its qualifier: `surface:3`
    /// becomes `build-box:surface:3`. Qualified refs, UUIDs and other ids
    /// are returned unchanged.
    public static func qualify(target: String, session: String) -> String {
        let pieces = target.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, Int(pieces[1]) != nil,
              ["surface", "tab", "pane", "workspace"].contains(pieces[0].lowercased()) else { return target }
        return "\(session):\(target)"
    }

    /// Whether `value` is an object ref, optionally session-qualified:
    /// `workspace:3` or `build-box:workspace:3`.
    public static func isHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 || pieces.count == 3 else { return false }
        if pieces.count == 3, pieces[0].isEmpty { return false }
        let kind = pieces[pieces.count - 2].lowercased()
        guard ["window", "workspace", "pane", "surface"].contains(kind) else { return false }
        if pieces.count == 3, kind == "window" { return false }
        return Int(pieces[pieces.count - 1]) != nil
    }

    /// Whether a listed object's ref names the ref a user typed. With a
    /// session scope the server lists only that session's objects, so an
    /// unqualified `workspace:2` names the listed `build-box:workspace:2`.
    public static func ref(_ listed: String?, matches wanted: String, scoped: Bool) -> Bool {
        guard let listed else { return false }
        if listed.lowercased() == wanted.lowercased() { return true }
        guard scoped, isHandleRef(wanted), wanted.split(separator: ":").count == 2 else { return false }
        return listed.lowercased().hasSuffix(":" + wanted.lowercased()) && listed.split(separator: ":").count == 3
    }
}
