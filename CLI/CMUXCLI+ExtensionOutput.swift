import Darwin
import Foundation

/// Output/formatting for `cmux extension …`: the usage text, list rendering,
/// the consent-preview renderer shared by install/update/submit, and the
/// terminal-safety helpers that keep untrusted extension metadata from
/// injecting escape sequences into what the user approves.
extension CMUXCLI {
    /// Usage for `cmux extension`, returned by the CLI usage switch.
    static var extensionUsageText: String {
        String(localized: "cli.extension.usage", defaultValue: """
        Usage: cmux extension <list|install|submit|update|uninstall|link|unlink|open|config-dir|paths> [args] [--json]
        Dock TUI extensions: GitHub repos with a cmux-extension.json manifest, run as Dock panes.
        Commands:
          list                          Installed extensions and their panes
          install <owner/repo[/sub]>    Preview the pinned commit + commands, confirm, install
              [--ref <ref>] [--yes]     --ref pins a branch/tag/SHA; --yes skips the prompt
          submit <owner/repo[/sub]>     Validate and open a prefilled supported-listing issue
              [--ref <ref>] [--no-open] --json prints the issue URL without opening it
          update <id> [--yes]           Re-resolve the source and re-consent to the new commit
          uninstall <id>                Remove the extension and its checkout (config/state kept)
          link <path>                   Register a local directory for development (no pin/build)
          unlink <id>                   Remove the record without touching files
          open <id | id.pane>           Open an extension pane in the Dock
          config-dir <id>               Print the extension's config directory
          paths <id>                    Print root, config, state, and logs directories
        Supported listings are reviewed by cmux before they appear. Manifest docs: https://ncmux.com/docs/extensions
        """)
    }

    func printExtensionResult(
        _ payload: [String: Any],
        jsonOutput: Bool,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print(fallbackText)
        }
    }

    func printExtensionList(_ payload: [String: Any]) {
        let extensions = payload["extensions"] as? [[String: Any]] ?? []
        if extensions.isEmpty {
            print(String(
                localized: "cli.extension.listEmpty",
                defaultValue: "No extensions installed. Install one with: cmux extension install <owner/repo>"
            ))
            return
        }
        let tty = isatty(fileno(stdout)) != 0
        for entry in extensions {
            let id = ((entry["id"] as? String) ?? "?").cmuxTerminalSafe()
            let name = ((entry["name"] as? String) ?? id).cmuxTerminalSafe()
            let version = (entry["version"] as? String).map { " \($0.cmuxTerminalSafe())" } ?? ""
            let source = ((entry["source"] as? String) ?? "").cmuxTerminalSafe()
            let enabled = (entry["enabled"] as? Bool) ?? true
            let linked = (entry["linked"] as? Bool) ?? false
            let status = ((entry["status"] as? String) ?? "ok").cmuxTerminalSafe()
            var detail = linked
                ? String(localized: "cli.extension.list.linked", defaultValue: "linked")
                : ((entry["pinned_sha"] as? String)?.prefix(7)).map(String.init) ?? ""
            if !enabled {
                detail += detail.isEmpty ? "" : ", "
                detail += String(localized: "cli.extension.list.disabled", defaultValue: "disabled")
            }
            if status != "ok" {
                detail += detail.isEmpty ? "" : ", "
                detail += status
            }
            let dim = ExtensionAnsi.dim(tty)
            let bold = ExtensionAnsi.bold(tty)
            let reset = ExtensionAnsi.reset(tty)
            print("\(bold)\(id)\(reset)  \(name)\(version)  \(dim)\(source)\(detail.isEmpty ? "" : "  (\(detail))")\(reset)")
            for pane in entry["panes"] as? [[String: Any]] ?? [] {
                let qualifiedId = ((pane["qualified_id"] as? String) ?? "?").cmuxTerminalSafe()
                let title = ((pane["title"] as? String) ?? "").cmuxTerminalSafe()
                print("  \(dim)pane\(reset) \(qualifiedId)  \(title)")
            }
        }
    }

    /// Renders the same consent surface as the GUI sheet, in text: identity,
    /// pinned commit, warnings, and every command that will run.
    static func printExtensionInstallPreview(_ preview: [String: Any]) {
        let tty = isatty(fileno(stdout)) != 0
        let bold = ExtensionAnsi.bold(tty)
        let dim = ExtensionAnsi.dim(tty)
        let yellow = ExtensionAnsi.yellow(tty)
        let reset = ExtensionAnsi.reset(tty)

        let name = ((preview["name"] as? String) ?? "?").cmuxTerminalSafe()
        let version = ((preview["version"] as? String) ?? "").cmuxTerminalSafe()
        let source = ((preview["source"] as? String) ?? "").cmuxTerminalSafe()
        let sha = ((preview["resolved_sha"] as? String)?.prefix(7)).map(String.init) ?? "?"
        print("\(bold)\(name) \(version)\(reset)  \(dim)\(source) @ \(sha)\(reset)")
        if let description = preview["description"] as? String {
            print("  \(description.cmuxTerminalSafe())")
        }
        if (preview["kind"] as? String) == "update", let previous = preview["previous_sha"] as? String {
            print(String(
                localized: "cli.extension.preview.updateFrom",
                defaultValue: "  update: \(String(previous.prefix(7))) → \(sha)"
            ))
        }
        print(String(
            localized: "cli.extension.preview.trust",
            defaultValue: "\(yellow)Not reviewed by cmux. It will run as you, with your environment.\(reset) Installing pins it to \(sha) and enables the Dock beta feature."
        ))
        for warning in preview["warnings"] as? [String] ?? [] {
            print("\(yellow)warning:\(reset) \(warning.cmuxTerminalSafe())")
        }
        let buildCommands = preview["build_commands"] as? [String] ?? []
        if !buildCommands.isEmpty {
            print(String(
                localized: "cli.extension.preview.buildHeader",
                defaultValue: "Runs once at install:"
            ))
            for command in buildCommands {
                print("  \(dim)$\(reset) \(command.cmuxTerminalSafe())")
            }
        }
        let panes = preview["panes"] as? [[String: Any]] ?? []
        if !panes.isEmpty {
            print(String(
                localized: "cli.extension.preview.panesHeader",
                defaultValue: "Runs when you open its Dock panes:"
            ))
            for pane in panes {
                let paneId = ((pane["id"] as? String) ?? "?").cmuxTerminalSafe()
                let title = ((pane["title"] as? String) ?? "").cmuxTerminalSafe()
                print("  \(paneId)  \(title)")
                if let command = pane["command"] as? String {
                    print("    \(dim)$\(reset) \(command.cmuxTerminalSafe())")
                }
                if let cwd = pane["cwd"] as? String {
                    print("    \(dim)cwd: \(cwd.cmuxTerminalSafe())/\(reset)")
                }
                if let env = pane["env"] as? [String: String], !env.isEmpty {
                    for key in env.keys.sorted() {
                        print("    \(dim)env \(key.cmuxTerminalSafe())=\((env[key] ?? "").cmuxTerminalSafe())\(reset)")
                    }
                }
            }
        }
    }
}

extension String {
    /// The string with control characters (ESC, C0/C1, DEL) replaced, so
    /// untrusted extension metadata cannot repaint or forge the consent
    /// preview with embedded escape sequences. Newlines survive only where
    /// the layout expects multi-line content.
    func cmuxTerminalSafe(allowNewlines: Bool = false) -> String {
        String(unicodeScalars.map { scalar -> Character in
            if scalar == "\n" { return allowNewlines ? "\n" : " " }
            if scalar == "\t" { return " " }
            if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                return "\u{FFFD}"
            }
            // Invisible format characters can visually reorder or hide what
            // the user approves: bidi embedding/overrides and isolates,
            // zero-widths, BOM, and the rest of category Cf.
            if scalar.properties.generalCategory == .format {
                return "\u{FFFD}"
            }
            return Character(scalar)
        })
    }
}

/// ANSI helpers for extension CLI output, gated on TTY (mirrors the
/// install-preview helper's private styling).
private enum ExtensionAnsi {
    static func reset(_ tty: Bool) -> String { tty ? "\u{001B}[0m" : "" }
    static func bold(_ tty: Bool) -> String { tty ? "\u{001B}[1m" : "" }
    static func dim(_ tty: Bool) -> String { tty ? "\u{001B}[2m" : "" }
    static func yellow(_ tty: Bool) -> String { tty ? "\u{001B}[33m" : "" }
}
