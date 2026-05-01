import AppKit
import SwiftUI

struct DockEmptyView: View {
    @State private var isPromptPopoverPresented = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(localized: "dock.empty.title", defaultValue: "No Dock Controls"))
                .font(.system(size: 13, weight: .semibold))
            Text(String(
                localized: "dock.empty.subtitle",
                defaultValue: "Add controls to .cmux/dock.json."
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
            defaultValue: "Add cmux Dock controls for this repo. Create .cmux/dock.json with a controls array. Each control needs id, title, command, and optional cwd, height, env. Use safe commands for this repo and do not include secrets. Include a Feed control only if cmux feed tui --opentui is useful. Add useful controls for this project, such as git, logs, dev server status, task queue, or test watcher."
        )
    }
}
