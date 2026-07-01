/// CLI command spec — the single source of truth for what flags each relay
/// command accepts. The relay generator (daemon/remote/cmd/cmuxd-remote/gen)
/// reads this via `system.command_spec` and produces commands_generated.go.
/// Update this table whenever a CLI command gains or loses a flag.
extension TerminalController {

    // MARK: - Spec types

    struct CLIFlagSpec {
        let name: String
        let type: String // "string" | "bool" | "repeatable"

        static func str(_ name: String) -> Self { .init(name: name, type: "string") }
        static func bool(_ name: String) -> Self { .init(name: name, type: "bool") }
        static func rep(_ name: String) -> Self { .init(name: name, type: "repeatable") }

        var dict: [String: Any] { ["name": name, "type": type] }
    }

    struct CLICommandEntry {
        /// Primary CLI command name (e.g. "new-workspace").
        let name: String
        /// v2 JSON-RPC method the command maps to.
        let method: String
        /// Declared flags. The generator uses `type` to decide flagKeys/boolFlags/repeatKeys.
        let flags: [CLIFlagSpec]
        /// Param key for the positional argument, if any (e.g. "text" for `send`).
        let positional: String?
        /// Additional CLI names that route to the same command.
        let aliases: [String]

        init(
            _ name: String,
            method: String,
            flags: [CLIFlagSpec] = [],
            positional: String? = nil,
            aliases: [String] = []
        ) {
            self.name = name
            self.method = method
            self.flags = flags
            self.positional = positional
            self.aliases = aliases
        }

        var dict: [String: Any] {
            var d: [String: Any] = ["method": method, "flags": flags.map(\.dict)]
            if let p = positional { d["positional"] = p }
            if !aliases.isEmpty { d["aliases"] = aliases }
            return d
        }
    }

    // MARK: - Canonical spec table

    nonisolated static let cliCommandEntries: [CLICommandEntry] = [

        // ── System ───────────────────────────────────────────────────────────
        .init("ping",         method: "system.ping"),
        .init("capabilities", method: "system.capabilities"),

        // ── Windows ──────────────────────────────────────────────────────────
        .init("list-windows",   method: "window.list"),
        .init("current-window", method: "window.current"),
        .init("new-window",     method: "window.create"),
        .init("focus-window",   method: "window.focus",  flags: [.str("window")]),
        .init("close-window",   method: "window.close",  flags: [.str("window")]),

        // ── Workspaces ───────────────────────────────────────────────────────
        .init("list-workspaces", method: "workspace.list", flags: [.str("window")]),
        .init("new-workspace", method: "workspace.create", flags: [
            .str("name"), .str("cwd"), .str("description"), .bool("focus"),
            .str("window"), .str("group"), .str("group-placement"), .str("group-reference"),
            .str("layout"), .rep("env"), .str("env-file"), .str("command"),
        ]),
        .init("rename-workspace", method: "workspace.rename",
              flags: [.str("workspace"), .str("window")],
              positional: "title",
              aliases: ["rename-window"]),
        .init("close-workspace",    method: "workspace.close",    flags: [.str("workspace"), .str("window")]),
        .init("select-workspace",   method: "workspace.select",   flags: [.str("workspace"), .str("window")]),
        .init("current-workspace",  method: "workspace.current",  flags: [.str("window")]),
        .init("next-workspace",     method: "workspace.next",     flags: [.str("window")]),
        .init("previous-workspace", method: "workspace.previous", flags: [.str("window")]),
        .init("last-workspace",     method: "workspace.last",     flags: [.str("window")]),
        .init("move-workspace-to-window", method: "workspace.move_to_window",
              flags: [.str("workspace"), .str("window")]),
        .init("equalize-splits", method: "workspace.equalize_splits",
              flags: [.str("workspace"), .str("window")]),

        // ── Panes ────────────────────────────────────────────────────────────
        .init("list-panes",       method: "pane.list",     flags: [.str("workspace"), .str("window")]),
        .init("list-pane-surfaces", method: "pane.surfaces",
              flags: [.str("pane"), .str("workspace"), .str("window")]),
        .init("new-pane", method: "pane.create", flags: [
            .str("type"), .str("direction"), .str("placement"),
            .str("workspace"), .str("window"), .str("url"), .bool("focus"),
        ]),
        .init("last-pane",   method: "pane.last",   flags: [.str("workspace"), .str("window")]),
        .init("resize-pane", method: "pane.resize", flags: [
            .str("pane"), .str("workspace"), .str("window"), .str("direction"), .str("amount"),
        ]),
        .init("swap-pane", method: "pane.swap", flags: [
            .str("pane"), .str("target-pane"), .str("workspace"), .str("window"), .bool("focus"),
        ]),
        .init("break-pane", method: "pane.break", flags: [
            .str("pane"), .str("surface"), .str("workspace"), .str("window"), .bool("focus"),
        ]),
        .init("join-pane", method: "pane.join", flags: [
            .str("target-pane"), .str("pane"), .str("surface"),
            .str("workspace"), .str("window"), .bool("focus"),
        ]),

        // ── Surfaces ─────────────────────────────────────────────────────────
        .init("list-panels",  method: "surface.list",   flags: [.str("workspace"), .str("window")]),
        .init("focus-panel",  method: "surface.focus",  flags: [.str("panel"), .str("workspace"), .str("window")]),
        .init("new-surface", method: "surface.create", flags: [
            .str("type"), .str("pane"), .str("placement"), .str("workspace"), .str("window"),
            .str("url"), .str("provider"), .str("renderer"), .str("working-directory"), .bool("focus"),
        ]),
        .init("new-split", method: "surface.split",
              flags: [.str("surface"), .str("panel"), .str("workspace"), .str("window"), .bool("focus")],
              positional: "direction"),
        .init("close-surface", method: "surface.close",
              flags: [.str("surface"), .str("panel"), .str("workspace"), .str("window")]),
        .init("send",     method: "surface.send_text",
              flags: [.str("surface"), .str("workspace"), .str("window")],
              positional: "text"),
        .init("send-key", method: "surface.send_key",
              flags: [.str("surface"), .str("workspace"), .str("window")],
              positional: "key"),
        .init("read-screen", method: "surface.read_text", flags: [
            .str("surface"), .str("workspace"), .str("window"), .bool("scrollback"), .str("lines"),
        ]),
        .init("clear-history",    method: "surface.clear_history", flags: [.str("surface"), .str("workspace"), .str("window")]),
        .init("refresh-surfaces", method: "surface.refresh"),

        // ── Notifications ────────────────────────────────────────────────────
        .init("notify", method: "notification.create", flags: [
            .str("title"), .str("subtitle"), .str("body"),
            .str("workspace"), .str("surface"), .str("window"),
        ]),
        .init("dismiss-notification",   method: "notification.dismiss",
              flags: [.str("id"), .bool("all-read")]),
        .init("mark-notification-read", method: "notification.mark_read",
              flags: [.str("id"), .str("workspace"), .str("surface"), .str("window"), .bool("all")]),
        .init("open-notification",  method: "notification.open",          flags: [.str("id")]),
        .init("jump-to-unread",     method: "notification.jump_to_unread"),
    ]

    // MARK: - RPC handler

    nonisolated func v2CLICommandSpec() -> [String: Any] {
        var commands: [String: Any] = [:]
        for entry in Self.cliCommandEntries {
            commands[entry.name] = entry.dict
            for alias in entry.aliases {
                commands[alias] = entry.dict
            }
        }
        return ["commands": commands]
    }
}
