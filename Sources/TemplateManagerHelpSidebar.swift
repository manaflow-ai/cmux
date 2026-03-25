import SwiftUI

/// Right sidebar for the Template Manager window.
/// Shows YAML format reference and a searchable list of cmux socket commands.
struct TemplateManagerHelpSidebar: View {
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(
                localized: "templateManager.help.title",
                defaultValue: "Reference"
            ))
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    yamlReferenceSection
                    Divider()
                    commandListSection
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - YAML Reference

    @ViewBuilder
    private var yamlReferenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                localized: "templateManager.help.yamlFormat",
                defaultValue: "YAML Format"
            ))
            .font(.subheadline.bold())

            yamlHint(
                "root:",
                String(localized: "templateManager.help.rootNode", defaultValue: "Root workspace node")
            )
            yamlHint(
                "  title:",
                String(localized: "templateManager.help.title.field", defaultValue: "Workspace title")
            )
            yamlHint(
                "  color:",
                String(localized: "templateManager.help.color", defaultValue: "Hex color (e.g. \"#FF0000\")")
            )
            yamlHint(
                "  command:",
                String(localized: "templateManager.help.command", defaultValue: "Startup command (string or |)")
            )
            yamlHint(
                "  children:",
                String(localized: "templateManager.help.children", defaultValue: "List of child workspaces")
            )
        }
    }

    private func yamlHint(_ key: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.accentColor)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Command List

    @ViewBuilder
    private var commandListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                localized: "templateManager.help.commands",
                defaultValue: "cmux Commands"
            ))
            .font(.subheadline.bold())

            TextField(
                String(localized: "templateManager.help.search", defaultValue: "Search commands…"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)

            let commands = filteredCommands
            ForEach(commands, id: \.self) { command in
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }

            if commands.isEmpty {
                Text(String(
                    localized: "templateManager.help.noResults",
                    defaultValue: "No matching commands"
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    private var filteredCommands: [String] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return Self.allCommands }
        return Self.allCommands.filter { $0.lowercased().contains(query) }
    }

    // MARK: - Command List Data

    // swiftlint:disable line_length
    static let allCommands: [String] = [
        "system.ping",
        "system.capabilities",
        "system.identify",
        "system.tree",
        "auth.login",
        "window.list",
        "window.current",
        "window.focus",
        "window.create",
        "window.close",
        "workspace.list",
        "workspace.create",
        "workspace.select",
        "workspace.current",
        "workspace.close",
        "workspace.move_to_window",
        "workspace.reorder",
        "workspace.rename",
        "workspace.action",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.remote.configure",
        "workspace.remote.reconnect",
        "workspace.remote.disconnect",
        "workspace.remote.status",
        "surface.list",
        "surface.current",
        "surface.focus",
        "surface.split",
        "surface.create",
        "surface.close",
        "surface.move",
        "surface.reorder",
        "surface.action",
        "surface.send_text",
        "surface.send_key",
        "surface.read_text",
        "surface.clear_history",
        "pane.list",
        "pane.focus",
        "pane.surfaces",
        "pane.create",
        "pane.resize",
        "pane.swap",
        "pane.break",
        "pane.join",
        "pane.last",
        "notification.create",
        "notification.list",
        "notification.clear",
        "browser.open_split",
        "browser.navigate",
        "browser.back",
        "browser.forward",
        "browser.reload",
        "browser.url.get",
        "browser.snapshot",
        "browser.eval",
        "browser.click",
        "browser.type",
        "browser.fill",
        "browser.press",
        "browser.screenshot",
        "browser.get.text",
        "browser.get.html",
        "browser.get.title",
        "group.create",
        "group.list",
        "group.delete",
        "group.rename",
        "group.set_color",
        "group.add_workspace",
        "group.remove_workspace",
        "group.install_template",
        "project.open",
        "project.open_template",
        "script.list",
        "script.get",
        "script.save",
        "script.delete",
        "template.list",
        "template.get",
        "template.save",
        "template.delete",
        "settings.open",
        "feedback.open",
        "feedback.submit",
        "markdown.open",
        "tab.action",
    ]
    // swiftlint:enable line_length
}
