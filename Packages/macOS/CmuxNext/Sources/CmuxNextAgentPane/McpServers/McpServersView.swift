public import SwiftUI

/// Settings > MCP Servers: every MCP connection the person approved, with its facts, tools and
/// controls. Each change is the person's click on this view; the model only reads acpmux again
/// after it.
public struct McpServersView: View {
    let model: McpServersModel
    let confirmRemove: @MainActor (_ connection: McpServerConnection, _ remove: @escaping @MainActor () -> Void) -> Void

    /// The tab title ("MCP Servers", localized).
    public static var paneTitle: String { McpServersStrings.title }

    /// - Parameters:
    ///   - model: The page's state.
    ///   - confirmRemove: Asks the person whether to remove `connection` (a cmux dialog) and calls
    ///     `remove` only on their yes.
    public init(model: McpServersModel,
                confirmRemove: @escaping @MainActor (_ connection: McpServerConnection, _ remove: @escaping @MainActor () -> Void) -> Void) {
        self.model = model
        self.confirmRemove = confirmRemove
    }

    public var body: some View {
        let rows = orderedConnections
        let busy = model.busy
        let focused = model.focusedID
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = model.notice {
                HStack {
                    Text(McpServersStrings.notice(notice)).font(.callout)
                    Spacer()
                    Button { model.dismissNotice() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
            }
            if let unknown = model.unknownReference {
                Text(McpServersStrings.unknownReference(unknown)).font(.callout).foregroundStyle(.orange)
            }
            if model.isLoading {
                Text(McpServersStrings.loading).foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text(McpServersStrings.empty).foregroundStyle(.secondary)
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { connection in
                            McpServerRowView(connection: connection, isBusy: busy.contains(connection.id),
                                             isFocused: connection.id == focused, actions: actions(for: connection))
                                .id(connection.id)
                        }
                    }
                }
                .onChange(of: focused) { _, id in
                    if let id { reader.scrollTo(id, anchor: .top) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.reload() }
        .sheet(isPresented: Binding(get: { model.auditLines != nil }, set: { if !$0 { model.hideAudit() } })) {
            McpAuditLogView(lines: model.auditLines ?? [], close: { model.hideAudit() })
        }
        .accessibilityIdentifier("cmux.mcpServers.pane")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(McpServersStrings.title).font(.title2.weight(.semibold))
                Text(McpServersStrings.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(McpServersStrings.viewAudit) { Task { await model.showAudit() } }
            Button(McpServersStrings.reload) { Task { await model.reload() } }
        }
    }

    /// The focused connection first, then the rest in the daemon's order.
    private var orderedConnections: [McpServerConnection] {
        let all = model.connections
        guard let focused = model.focusedID, let index = all.firstIndex(where: { $0.id == focused }) else { return all }
        var ordered = all
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    private func actions(for connection: McpServerConnection) -> McpServerRowActions {
        let model = model, confirmRemove = confirmRemove, id = connection.id
        return McpServerRowActions(
            setPolicy: { policy, tool in Task { await model.setPolicy(policy, tool: tool, of: id) } },
            remove: { confirmRemove(connection) { Task { await model.remove(id) } } },
            signIn: { Task { await model.signIn(id) } },
            saveKey: { key in Task { await model.saveKey(key, for: id) } },
            approveTools: { Task { await model.approveTools(id) } })
    }
}
