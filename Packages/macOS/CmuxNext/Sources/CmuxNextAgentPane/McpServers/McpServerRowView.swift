import CmuxNextDesign
import SwiftUI

/// One connection in Settings > MCP Servers: title, exact URL, publisher and whether it is
/// verified, scope, state, each tool with its policy, the tools acpmux holds after they changed,
/// and the person's controls (policy menus, Approve Changed Tools, Sign In, a private key field,
/// Remove, which asks first).
struct McpServerRowView: View {
    let connection: McpServerConnection
    let isBusy: Bool
    let isFocused: Bool
    let actions: McpServerRowActions

    /// The key being typed; cleared right after Save Key, never kept anywhere else.
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            facts
            if !connection.held.isEmpty { held }
            tools
            if connection.takesKey { keyField }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isFocused ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isFocused ? 2 : 1))
        .disabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmux.mcpServers.row.\(connection.name)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(connection.title.isEmpty ? connection.name : connection.title).font(.headline)
            Text(connection.name).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            if isBusy { ThemedSpinner(size: 16) }
            if connection.signsIn {
                Button(connection.hasSecret ? McpServersStrings.signInAgain : McpServersStrings.signIn) { actions.signIn() }
            }
            // Asks first: the page's cmux dialog (McpServersView's confirmRemove), with its key hints.
            Button(McpServersStrings.remove, role: .destructive) { actions.remove() }
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text(McpServersStrings.url).foregroundStyle(.secondary)
                Text(connection.url).font(.callout.monospaced()).textSelection(.enabled)
            }
            GridRow {
                Text(McpServersStrings.publisher).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(connection.publisher)
                    Label(connection.verified ? McpServersStrings.verified : McpServersStrings.unverified,
                          systemImage: connection.verified ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(connection.verified ? Color.green : Color.orange)
                        .font(.caption)
                }
            }
            GridRow {
                Text(McpServersStrings.scope).foregroundStyle(.secondary)
                Text(McpServersStrings.scope(connection.scope))
            }
            GridRow {
                Text(McpServersStrings.state).foregroundStyle(.secondary)
                Text(McpServersStrings.state(connection.state))
                    .foregroundStyle(connection.state == "connected" ? Color.primary : Color.orange)
            }
        }
        .font(.callout)
    }

    /// The tools acpmux holds from agents until the person approves them.
    private var held: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(McpServersStrings.heldTitle, systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.orange)
            Text(McpServersStrings.heldNote).font(.callout).foregroundStyle(.secondary)
            Text(connection.held.joined(separator: ", ")).font(.callout.monospaced()).textSelection(.enabled)
            Button(McpServersStrings.approveTools) { actions.approveTools() }
                .accessibilityIdentifier("cmux.mcpServers.approveTools.\(connection.name)")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmux.mcpServers.held.\(connection.name)")
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(McpServersStrings.tools).font(.subheadline.weight(.semibold))
            if connection.tools.isEmpty {
                Text(McpServersStrings.noTools).foregroundStyle(.secondary).font(.callout)
            }
            ForEach(connection.tools) { tool in
                HStack {
                    Text(tool.name).font(.callout.monospaced())
                    if connection.held.contains(tool.name) {
                        Text(McpServersStrings.heldBadge).font(.caption).foregroundStyle(Color.orange)
                    }
                    Spacer()
                    Picker(tool.name, selection: Binding(get: { tool.policy }, set: { actions.setPolicy($0, tool.name) })) {
                        ForEach(McpToolPolicy.allCases) { policy in
                            Text(McpServersStrings.policy(policy)).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("cmux.mcpServers.policy.\(connection.name).\(tool.name)")
                }
            }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(McpServersStrings.keyPlaceholder, text: $key)
                    .textFieldStyle(.roundedBorder)
                    .focusEffectDisabled()
                    .onSubmit(send)
                Button(connection.hasSecret ? McpServersStrings.replaceKey : McpServersStrings.saveKey, action: send)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(McpServersStrings.keyPrivate).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func send() {
        let typed = key
        key = ""
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.saveKey(typed)
    }
}
