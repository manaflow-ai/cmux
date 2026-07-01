/// CLI command spec — the single source of truth for what flags each relay
/// command accepts AND how its help text reads. Both the Mac CLI's
/// subcommandUsage() and the relay generator (go generate ./cmd/cmuxd-remote/)
/// derive from this table. Update it whenever a command gains or loses a flag.
extension TerminalController {

    // MARK: - Spec types

    struct CLIFlagSpec {
        let name: String
        let type: String       // "string" | "bool" | "repeatable"
        let valueHint: String  // shown as --flag <hint>
        let description: String

        static func str(_ name: String, hint: String = "<value>", desc: String = "") -> Self {
            .init(name: name, type: "string", valueHint: hint, description: desc)
        }
        static func bool(_ name: String, desc: String = "") -> Self {
            .init(name: name, type: "bool", valueHint: "<true|false>", description: desc)
        }
        static func rep(_ name: String, hint: String = "<value>", desc: String = "") -> Self {
            .init(name: name, type: "repeatable", valueHint: hint, description: desc)
        }

        var dict: [String: Any] { ["name": name, "type": type] }
    }

    struct CLICommandEntry {
        let name: String
        let method: String
        let summary: String
        let flags: [CLIFlagSpec]
        /// Param key for the positional argument, if any (e.g. "text" for `send`).
        let positional: String?
        /// Display hint for the positional shown in the usage line (e.g. `<text>`).
        let positionalHint: String?
        let aliases: [String]
        let examples: [String]

        init(
            _ name: String,
            method: String,
            summary: String = "",
            flags: [CLIFlagSpec] = [],
            positional: String? = nil,
            positionalHint: String? = nil,
            aliases: [String] = [],
            examples: [String] = []
        ) {
            self.name = name
            self.method = method
            self.summary = summary
            self.flags = flags
            self.positional = positional
            self.positionalHint = positionalHint
            self.aliases = aliases
            self.examples = examples
        }

        var dict: [String: Any] {
            var d: [String: Any] = ["method": method, "flags": flags.map(\.dict)]
            if let p = positional { d["positional"] = p }
            if !aliases.isEmpty { d["aliases"] = aliases }
            return d
        }
    }

    // MARK: - Shared flag definitions

    private typealias F = CLIFlagSpec

    private static func workspace(_ desc: String = "Workspace context (default: $CMUX_WORKSPACE_ID)") -> F {
        .str("workspace", hint: "<id|ref|index>", desc: desc)
    }
    private static func surface(_ desc: String = "Surface context (default: $CMUX_SURFACE_ID)") -> F {
        .str("surface", hint: "<id|ref|index>", desc: desc)
    }
    private static let window  = F.str("window",  hint: "<id|ref|index>", desc: "Window context for ref and index resolution")
    private static let pane    = F.str("pane",    hint: "<id|ref|index>", desc: "Pane context (default: focused pane)")
    private static let panel   = F.str("panel",   hint: "<id|ref|index>", desc: "Alias for --surface")
    private static let focus   = F.bool("focus",   desc: "Focus the result (default: false)")
    private static let noFocus = F.bool("no-focus", desc: "Alias for --focus false")

    // MARK: - Canonical spec table

    nonisolated static let cliCommandEntries: [CLICommandEntry] = [

        // ── System ────────────────────────────────────────────────────────────
        .init("ping",
              method: "system.ping",
              summary: "Check connectivity to the cmux socket server.",
              examples: ["cmux ping"]),

        .init("capabilities",
              method: "system.capabilities",
              summary: "Print server capabilities as JSON.",
              examples: ["cmux capabilities"]),

        // ── Windows ───────────────────────────────────────────────────────────
        .init("list-windows",
              method: "window.list",
              summary: "List all open windows.",
              examples: ["cmux list-windows"]),

        .init("current-window",
              method: "window.current",
              summary: "Print the ID of the focused window.",
              examples: ["cmux current-window"]),

        .init("new-window",
              method: "window.create",
              summary: "Create a new window.",
              examples: ["cmux new-window"]),

        .init("focus-window",
              method: "window.focus",
              summary: "Bring the specified window to the front.",
              flags: [.str("window", hint: "<id|ref|index>", desc: "Window to focus (required)")],
              examples: ["cmux focus-window --window 0", "cmux focus-window --window window:1"]),

        .init("close-window",
              method: "window.close",
              summary: "Close the specified window.",
              flags: [.str("window", hint: "<id|ref|index>", desc: "Window to close (required)")],
              examples: ["cmux close-window --window 0"]),

        // ── Workspaces ────────────────────────────────────────────────────────
        .init("list-workspaces",
              method: "workspace.list",
              summary: "List workspaces in a window.",
              flags: [window],
              examples: ["cmux list-workspaces"]),

        .init("new-workspace",
              method: "workspace.create",
              summary: "Create a new workspace.",
              flags: [
                  .str("name",            hint: "<title>",        desc: "Workspace title"),
                  .str("cwd",             hint: "<path>",         desc: "Working directory"),
                  .str("description",     hint: "<text>",         desc: "Workspace description"),
                  focus,
                  window,
                  .str("group",           hint: "<id>",           desc: "Workspace group to place into"),
                  .str("group-placement", hint: "<before|after>", desc: "Placement within the group"),
                  .str("group-reference", hint: "<id>",           desc: "Reference workspace for placement"),
                  .str("layout",          hint: "<json>",         desc: "Pane layout JSON object"),
                  .rep("env",             hint: "KEY=VALUE",      desc: "Environment variable (repeatable)"),
                  .str("env-file",        hint: "<path>",         desc: "File of KEY=VALUE environment variables"),
                  .str("command",         hint: "<cmd>",          desc: "Command to send after creation"),
              ],
              examples: [
                  "cmux new-workspace",
                  "cmux new-workspace --name \"backend logs\" --cwd ~/code",
                  "cmux new-workspace --command \"claude .\" --focus true",
                  "cmux new-workspace --env FOO=bar --env BAZ=qux",
              ]),

        .init("rename-workspace",
              method: "workspace.rename",
              summary: "Rename a workspace. Defaults to the current workspace.",
              flags: [workspace(), window],
              positional: "title",
              positionalHint: "<title>",
              aliases: ["rename-window"],
              examples: [
                  "cmux rename-workspace \"backend logs\"",
                  "cmux rename-workspace --workspace workspace:2 \"agent run\"",
              ]),

        .init("close-workspace",
              method: "workspace.close",
              summary: "Close the specified workspace.",
              flags: [workspace("Workspace to close (required)"), window],
              examples: ["cmux close-workspace --workspace workspace:2"]),

        .init("select-workspace",
              method: "workspace.select",
              summary: "Switch to the specified workspace.",
              flags: [workspace("Workspace to select (required)"), window],
              examples: ["cmux select-workspace --workspace workspace:2", "cmux select-workspace --workspace 0"]),

        .init("current-workspace",
              method: "workspace.current",
              summary: "Print the selected workspace ID for a window.",
              flags: [window],
              examples: ["cmux current-workspace"]),

        .init("next-workspace",
              method: "workspace.next",
              summary: "Switch to the next workspace in the window.",
              flags: [window],
              examples: ["cmux next-workspace"]),

        .init("previous-workspace",
              method: "workspace.previous",
              summary: "Switch to the previous workspace in the window.",
              flags: [window],
              examples: ["cmux previous-workspace"]),

        .init("last-workspace",
              method: "workspace.last",
              summary: "Switch to the last-used workspace.",
              flags: [window],
              examples: ["cmux last-workspace"]),

        .init("move-workspace-to-window",
              method: "workspace.move_to_window",
              summary: "Move a workspace to a different window.",
              flags: [
                  workspace("Workspace to move (required)"),
                  .str("window", hint: "<id|ref|index>", desc: "Target window (required)"),
              ],
              examples: ["cmux move-workspace-to-window --workspace workspace:2 --window window:1"]),

        .init("equalize-splits",
              method: "workspace.equalize_splits",
              summary: "Equalize pane splits in a workspace.",
              flags: [workspace(), window],
              examples: ["cmux equalize-splits", "cmux equalize-splits --workspace workspace:2"]),

        // ── Panes ─────────────────────────────────────────────────────────────
        .init("list-panes",
              method: "pane.list",
              summary: "List panes in a workspace.",
              flags: [workspace(), window],
              examples: ["cmux list-panes", "cmux list-panes --workspace workspace:2"]),

        .init("list-pane-surfaces",
              method: "pane.surfaces",
              summary: "List surfaces in a pane.",
              flags: [pane, workspace(), window],
              examples: ["cmux list-pane-surfaces", "cmux list-pane-surfaces --pane pane:1"]),

        .init("new-pane",
              method: "pane.create",
              summary: "Create a new pane in the workspace.",
              flags: [
                  .str("type",      hint: "<terminal|browser>",    desc: "Pane type (default: terminal)"),
                  .str("direction", hint: "<left|right|up|down>",  desc: "Split direction (default: right)"),
                  .str("placement", hint: "<workspace|dock>",      desc: "Target container (default: workspace)"),
                  workspace(), window,
                  .str("url",       hint: "<url>",                 desc: "URL for browser panes"),
                  focus,
              ],
              examples: [
                  "cmux new-pane",
                  "cmux new-pane --type browser --direction down --url https://example.com",
                  "cmux new-pane --placement dock --type browser --url https://example.com",
              ]),

        .init("last-pane",
              method: "pane.last",
              summary: "Focus the previously focused pane in a workspace.",
              flags: [workspace(), window],
              examples: ["cmux last-pane"]),

        .init("resize-pane",
              method: "pane.resize",
              summary: "Resize a pane.",
              flags: [
                  pane,
                  workspace(), window,
                  .str("direction", hint: "<left|right|up|down>", desc: "Resize direction (default: right)"),
                  .str("amount",    hint: "<n>",                  desc: "Resize amount (default: 1)"),
              ],
              examples: [
                  "cmux resize-pane --direction right --amount 10",
                  "cmux resize-pane --pane pane:1 --direction up",
              ]),

        .init("swap-pane",
              method: "pane.swap",
              summary: "Swap two panes.",
              flags: [
                  pane,
                  .str("target-pane", hint: "<id|ref|index>", desc: "Target pane (required)"),
                  workspace(), window, focus,
              ],
              examples: ["cmux swap-pane --pane pane:1 --target-pane pane:2"]),

        .init("break-pane",
              method: "pane.break",
              summary: "Move a pane or surface out into its own pane context.",
              flags: [pane, surface(), workspace(), window, focus, noFocus],
              examples: ["cmux break-pane", "cmux break-pane --pane pane:2 --focus true"]),

        .init("join-pane",
              method: "pane.join",
              summary: "Join a pane or surface into another pane.",
              flags: [
                  .str("target-pane", hint: "<id|ref|index>", desc: "Target pane (required)"),
                  pane, surface(), workspace(), window, focus, noFocus,
              ],
              examples: ["cmux join-pane --target-pane pane:1"]),

        // ── Surfaces ──────────────────────────────────────────────────────────
        .init("list-panels",
              method: "surface.list",
              summary: "List surfaces (panels) in a workspace.",
              flags: [workspace(), window],
              examples: ["cmux list-panels", "cmux list-panels --workspace workspace:2"]),

        .init("focus-panel",
              method: "surface.focus",
              summary: "Focus a specific panel (surface).",
              flags: [
                  .str("panel", hint: "<id|ref|index>", desc: "Panel to focus (required)"),
                  workspace(), window,
              ],
              examples: ["cmux focus-panel --panel surface:2"]),

        .init("new-surface",
              method: "surface.create",
              summary: "Create a new surface (tab) in a pane.",
              flags: [
                  .str("type",              hint: "<terminal|browser|agent-session>", desc: "Surface type (default: terminal)"),
                  pane,
                  .str("placement",         hint: "<workspace|dock>",   desc: "Target container (default: workspace)"),
                  workspace(), window,
                  .str("url",               hint: "<url>",              desc: "URL for browser surfaces"),
                  .str("provider",          hint: "<codex|claude|opencode>", desc: "Provider for agent-session surfaces"),
                  .str("renderer",          hint: "<react|solid>",      desc: "Renderer for agent-session surfaces"),
                  .str("working-directory", hint: "<path>",             desc: "Working directory for terminal and agent surfaces"),
                  focus,
              ],
              examples: [
                  "cmux new-surface",
                  "cmux new-surface --type browser --pane pane:1 --url https://example.com",
                  "cmux new-surface --type agent-session --provider claude --focus true",
              ]),

        .init("new-split",
              method: "surface.split",
              summary: "Split the current pane in the given direction.",
              flags: [surface(), panel, workspace(), window, focus],
              positional: "direction",
              positionalHint: "<left|right|up|down>",
              examples: [
                  "cmux new-split right",
                  "cmux new-split down --workspace workspace:1",
              ]),

        .init("close-surface",
              method: "surface.close",
              summary: "Close a surface. Defaults to the focused surface.",
              flags: [surface("Surface to close (default: $CMUX_SURFACE_ID)"), panel, workspace(), window],
              examples: ["cmux close-surface", "cmux close-surface --surface surface:3"]),

        .init("send",
              method: "surface.send_text",
              summary: "Send text to a terminal surface. Escape sequences: \\n and \\r send Enter, \\t sends Tab.",
              flags: [surface(), workspace(), window],
              positional: "text",
              positionalHint: "<text>",
              examples: [
                  "cmux send \"echo hello\"",
                  "cmux send --surface surface:2 \"ls -la\\n\"",
              ]),

        .init("send-key",
              method: "surface.send_key",
              summary: "Send a key event to a terminal surface.",
              flags: [surface(), workspace(), window],
              positional: "key",
              positionalHint: "<key>",
              examples: [
                  "cmux send-key enter",
                  "cmux send-key --surface surface:2 ctrl+c",
              ]),

        .init("read-screen",
              method: "surface.read_text",
              summary: "Read terminal text from a surface as plain text.",
              flags: [
                  surface(), workspace(), window,
                  .bool("scrollback", desc: "Include scrollback (not just visible viewport)"),
                  .str("lines", hint: "<n>", desc: "Limit to the last n lines (implies --scrollback)"),
              ],
              examples: [
                  "cmux read-screen",
                  "cmux read-screen --surface surface:2 --scrollback --lines 200",
              ]),

        .init("clear-history",
              method: "surface.clear_history",
              summary: "Clear terminal scrollback history.",
              flags: [surface(), workspace(), window],
              examples: ["cmux clear-history"]),

        .init("refresh-surfaces",
              method: "surface.refresh",
              summary: "Refresh surface snapshots for the focused workspace.",
              examples: ["cmux refresh-surfaces"]),

        // ── Notifications ─────────────────────────────────────────────────────
        .init("notify",
              method: "notification.create",
              summary: "Send a notification to a workspace or surface.",
              flags: [
                  .str("title",    hint: "<text>",          desc: "Notification title (default: \"Notification\")"),
                  .str("subtitle", hint: "<text>",          desc: "Notification subtitle"),
                  .str("body",     hint: "<text>",          desc: "Notification body"),
                  workspace(), surface(), window,
              ],
              examples: [
                  "cmux notify --title \"Build done\" --body \"All tests passed\"",
                  "cmux notify --title \"Error\" --subtitle \"test.swift\" --body \"Line 42: syntax error\"",
              ]),

        .init("dismiss-notification",
              method: "notification.dismiss",
              summary: "Remove one notification, or remove every already-read notification.",
              flags: [
                  .str("id",       hint: "<uuid>", desc: "Notification id to remove"),
                  .bool("all-read",               desc: "Remove every already-read notification"),
              ],
              examples: ["cmux dismiss-notification --id <uuid>", "cmux dismiss-notification --all-read"]),

        .init("mark-notification-read",
              method: "notification.mark_read",
              summary: "Mark notifications read without opening them.",
              flags: [
                  .str("id",  hint: "<uuid>", desc: "Mark one notification read"),
                  workspace("Mark notifications for a workspace"),
                  surface("Narrow --workspace to one surface"),
                  window,
                  .bool("all", desc: "Mark every notification read"),
              ],
              examples: [
                  "cmux mark-notification-read --id <uuid>",
                  "cmux mark-notification-read --all",
              ]),

        .init("open-notification",
              method: "notification.open",
              summary: "Focus the notification's workspace and surface, then mark it read.",
              flags: [.str("id", hint: "<uuid>", desc: "Notification id to open")],
              examples: ["cmux open-notification --id <uuid>"]),

        .init("jump-to-unread",
              method: "notification.jump_to_unread",
              summary: "Focus the latest unread notification.",
              examples: ["cmux jump-to-unread"]),
    ]

    // MARK: - Help text renderer

    nonisolated static func cliHelpText(for entry: CLICommandEntry) -> String {
        var usageLine = "cmux \(entry.name)"
        if let hint = entry.positionalHint {
            usageLine += " \(hint)"
        }
        if !entry.flags.isEmpty {
            usageLine += " [flags]"
        }

        var lines: [String] = ["Usage: \(usageLine)", ""]

        if !entry.summary.isEmpty {
            lines += [entry.summary, ""]
        }

        if !entry.flags.isEmpty {
            lines.append("Flags:")
            let col = 38 // description column
            for flag in entry.flags {
                let left: String
                if flag.type == "bool" {
                    left = "  --\(flag.name) <true|false>"
                } else {
                    left = "  --\(flag.name) \(flag.valueHint)"
                }
                if flag.description.isEmpty {
                    lines.append(left)
                } else {
                    let pad = String(repeating: " ", count: max(1, col - left.count))
                    lines.append("\(left)\(pad)\(flag.description)")
                }
            }
            lines.append("")
        }

        if !entry.examples.isEmpty {
            lines.append("Example:")
            for ex in entry.examples {
                lines.append("  \(ex)")
            }
        }

        return lines.joined(separator: "\n")
    }

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
