import AppKit
import SwiftUI

struct DockEmptyView: View {
    @State private var isPromptPopoverPresented = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(localized: "dock.empty.title", defaultValue: "No Dock Entries"))
                .font(.system(size: 13, weight: .semibold))
            Text(String(
                localized: "dock.empty.subtitle",
                defaultValue: "Add terminal or browser entries to .cmux/dock.json."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Button {
                        copyAgentPrompt()
                    } label: {
                        Label(
                            String(localized: "dock.empty.copyPrompt", defaultValue: "Copy Agent Prompt"),
                            systemImage: "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(String(localized: "dock.empty.copyPrompt.help", defaultValue: "Copy a prompt you can paste into an AI coding agent"))

                    Button {
                        isPromptPopoverPresented.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "dock.empty.promptInfo", defaultValue: "Show Agent Prompt"))
                    .help(String(localized: "dock.empty.promptInfo.help", defaultValue: "Show the prompt that will be copied"))
                    .popover(isPresented: $isPromptPopoverPresented, arrowEdge: .bottom) {
                        agentPromptPopover
                    }
                }

                Button {
                    openDockDocs()
                } label: {
                    Label(
                        String(localized: "dock.empty.openDocs", defaultValue: "Docs"),
                        systemImage: "questionmark.circle"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(localized: "dock.empty.openDocs.help", defaultValue: "Open the Dock documentation"))
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agentPromptPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "dock.empty.promptPopoverTitle", defaultValue: "Agent Prompt"))
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(agentPrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 320, height: 180)
        }
        .padding(14)
    }

    private func copyAgentPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(agentPrompt, forType: .string)
    }

    private func openDockDocs() {
        guard let url = URL(string: "https://cmux.com/docs/dock") else { return }
        NSWorkspace.shared.open(url)
    }

    private var agentPrompt: String {
        String(
            localized: "dock.empty.agentPrompt",
            defaultValue: """
            Set up cmux Dock entries for the current context.

            First, learn the feature before editing:
            1. Run `cmux docs dock` if the cmux CLI is available. If it is not, read https://cmux.com/docs/dock.
            2. Inspect the repository or current directory to understand the project type, scripts, package manager, dev servers, logs, task runners, test commands, browser dashboards, docs, admin consoles, and any existing TUI tools.
            3. If the desired Dock is ambiguous, ask the user what they want monitored or controlled before writing files.

            Dock is cmux's right-sidebar composable pane area. A Dock config is JSON with a top-level `controls` array. Each entry is either a terminal entry that runs a command in its own Ghostty-backed terminal section using the user's login shell, or a browser entry that opens with the same cmux browser stack used by workspace browser panes. Entries are useful for project dashboards, git/status views, dev server or build status, test watchers, log tails, queues, local services, browser dashboards, docs, admin consoles, or a custom TUI such as `cmux feed tui --opentui` when that feed is useful.

            Choose where to write the config:
            - In a repository or project directory, create or edit `.cmux/dock.json` so teammates can share it.
            - For a personal default outside a repo, create or edit `~/.config/cmux/dock.json`.
            - If both exist, project `.cmux/dock.json` is more specific for that project. Nested project configs apply to that directory tree; use the nearest relevant project config instead of writing unrelated entries globally.
            - If there is no repo and no clear project root, use the global config only after confirming the user wants a personal Dock.

            Schema:
            {
              "controls": [
                {
                  "id": "short-stable-id",
                  "title": "Human label",
                  "kind": "terminal",
                  "command": "safe command to run",
                  "cwd": "optional/path",
                  "height": 220,
                  "env": { "NAME": "value" }
                },
                {
                  "id": "browser-dashboard",
                  "title": "Dashboard",
                  "kind": "browser",
                  "url": "https://example.com",
                  "profile": "optional browser profile name, slug, or UUID",
                  "height": 320
                }
              ]
            }

            Rules:
            - Keep ids stable, lowercase, and unique.
            - Omit `kind` for old terminal-only configs if you prefer; missing `kind` still means `terminal`.
            - Use `cwd` for subdirectories; relative paths resolve from the config base.
            - Use `height` only when an entry needs a fixed amount of vertical space.
            - Use `env` only for non-secret values needed by one terminal entry.
            - Use `url` only for browser entries. Use `profile` only when a specific cmux browser profile is needed.
            - Do not put secrets, tokens, or machine-specific private paths in a shared project config.
            - Prefer commands that are safe to start repeatedly and make sense in a terminal.
            - Do not invent unavailable scripts or URLs. Read package files, Makefiles, Procfiles, README docs, config files, and existing tooling first.
            - Keep shared project Docks portable for teammates. Put personal or machine-specific entries in the global Dock.

            Deliverable:
            - Create or update the appropriate dock.json.
            - Preserve existing useful entries unless the user asked to replace them.
            - Validate that the JSON parses.
            - Summarize what each entry does and any commands or URLs the user should review before trusting the Dock config.
            """
        )
    }
}
