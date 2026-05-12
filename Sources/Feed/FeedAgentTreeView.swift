import CMUXWorkstream
import SwiftUI

struct FeedAgentTreeView: View {
    let graph: WorkstreamAgentGraphSnapshot
    let rows: [FeedAgentTreeRow]
    let actions: FeedRowActions
    @Binding var collapsedNodeIds: Set<String>
    let selectedNodeId: String?
    let isKeyboardActive: Bool
    let scrollRequest: FeedAgentTreeScrollRequest?
    let onSelect: (WorkstreamAgentTreeNode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            treeScrollView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var treeScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                rowStack
            }
            .feedZeroScrollContentMargins()
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                proxy.scrollTo(request.nodeId, anchor: .center)
            }
        }
    }

    private var rowStack: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                rowView(for: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowView(for row: FeedAgentTreeRow) -> some View {
        let nodeId = row.node.id
        let rowIsSelected = selectedNodeId == nodeId
        return FeedAgentTreeRowView(
            row: row,
            isCollapsed: collapsedNodeIds.contains(nodeId),
            isSelected: rowIsSelected,
            isFocusActive: isKeyboardActive && rowIsSelected,
            onToggle: {
                toggle(nodeId)
            },
            onFocus: {
                onSelect(row.node)
                if let workstreamId = row.node.focusWorkstreamId {
                    actions.jump(workstreamId)
                }
            }
        )
        .equatable()
        .id(nodeId)
    }

    private var summaryBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(summaryText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
    }

    private var summaryText: String {
        let nodeText = String.localizedStringWithFormat(
            NSLocalizedString(
                "feed.agentTree.nodes",
                tableName: nil,
                bundle: .main,
                value: "%lld nodes",
                comment: "Agent tree node count"
            ),
            graph.nodeCount
        )
        let edgeText = String.localizedStringWithFormat(
            NSLocalizedString(
                "feed.agentTree.edges",
                tableName: nil,
                bundle: .main,
                value: "%lld edges",
                comment: "Agent tree edge count"
            ),
            graph.edgeCount
        )
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "feed.agentTree.summary",
                tableName: nil,
                bundle: .main,
                value: "%@ · %@ · depth %lld",
                comment: "Agent tree summary"
            ),
            nodeText,
            edgeText,
            graph.maxDepth
        )
    }

    private func toggle(_ id: String) {
        if collapsedNodeIds.contains(id) {
            collapsedNodeIds.remove(id)
        } else {
            collapsedNodeIds.insert(id)
        }
    }
}

struct FeedAgentTreeRow: Identifiable, Equatable {
    let node: WorkstreamAgentTreeNode
    let depth: Int

    var id: String { node.id }
}

private struct FeedAgentTreeRowView: View, Equatable {
    let row: FeedAgentTreeRow
    let isCollapsed: Bool
    let isSelected: Bool
    let isFocusActive: Bool
    let onToggle: () -> Void
    let onFocus: () -> Void

    static func == (lhs: FeedAgentTreeRowView, rhs: FeedAgentTreeRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.isCollapsed == rhs.isCollapsed
            && lhs.isSelected == rhs.isSelected
            && lhs.isFocusActive == rhs.isFocusActive
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                indentGuides
                disclosure
                statusIcon
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(row.node.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        metadataChips
                    }
                    if let task = row.node.taskDescription, !task.isEmpty {
                        Text(task)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(rowBackgroundFill)
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocus)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(maxWidth: .infinity)
                .frame(height: 1)
        }
        .help(helpText)
    }

    private var rowBackgroundFill: Color {
        guard isSelected else { return .clear }
        if isFocusActive {
            return tint.opacity(0.14)
        }
        return Color.primary.opacity(0.07)
    }

    private var indentGuides: some View {
        HStack(spacing: 5) {
            ForEach(0..<row.depth, id: \.self) { _ in
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: CGFloat(row.depth) * 6)
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.node.childCount > 0 {
            Button(action: onToggle) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12, height: 16)
            }
            .buttonStyle(.plain)
            .help(isCollapsed
                  ? String(localized: "feed.agentTree.expand", defaultValue: "Expand subtree")
                  : String(localized: "feed.agentTree.collapse", defaultValue: "Collapse subtree"))
        } else {
            Color.clear.frame(width: 12, height: 16)
        }
    }

    private var statusIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(tint)
            .frame(width: 14, height: 16)
    }

    private var metadataChips: some View {
        HStack(spacing: 4) {
            chip(text: statusLabel, fg: tint, bg: tint.opacity(0.14))
            if let source = row.node.source {
                chip(text: source.rawValue.capitalized, fg: .secondary, bg: Color.primary.opacity(0.08))
            }
            if let subagentType = row.node.subagentType, !subagentType.isEmpty {
                chip(text: subagentType, fg: .blue, bg: Color.blue.opacity(0.12))
            }
            if let model = row.node.model, !model.isEmpty {
                chip(text: model, fg: .secondary, bg: Color.primary.opacity(0.08))
            }
        }
    }

    private func chip(text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(fg)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bg)
            )
    }

    private var iconName: String {
        switch row.node.kind {
        case .session:
            switch row.node.status {
            case .waiting: return "exclamationmark.circle.fill"
            case .running: return "bolt.fill"
            case .idle: return "pause.circle.fill"
            case .done: return "checkmark.circle.fill"
            case .unknown: return "circle"
            }
        case .spawnRequest:
            return "arrow.triangle.branch"
        }
    }

    private var tint: Color {
        switch row.node.status {
        case .waiting: return .orange
        case .running: return .blue
        case .idle: return .secondary
        case .done: return .green
        case .unknown: return .secondary.opacity(0.8)
        }
    }

    private var statusLabel: String {
        switch row.node.status {
        case .running:
            return String(localized: "feed.agentTree.status.running", defaultValue: "running")
        case .waiting:
            return String(localized: "feed.agentTree.status.waiting", defaultValue: "waiting")
        case .idle:
            return String(localized: "feed.agentTree.status.idle", defaultValue: "idle")
        case .done:
            return String(localized: "feed.agentTree.status.done", defaultValue: "done")
        case .unknown:
            return String(localized: "feed.agentTree.status.unknown", defaultValue: "unknown")
        }
    }

    private var helpText: String {
        var lines = [row.node.title, statusLabel]
        if let task = row.node.taskDescription, !task.isEmpty {
            lines.append(task)
        }
        if let workstreamId = row.node.workstreamId {
            lines.append(workstreamId)
        }
        return lines.joined(separator: "\n")
    }
}
