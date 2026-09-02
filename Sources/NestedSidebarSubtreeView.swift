import CmuxNestedTopology
import SwiftUI

/// Expandable provider-owned nested topology beneath a host terminal surface.
///
/// Snapshot-boundary safe: takes an immutable ``NestedSidebarSubtreeSnapshot``
/// and closure actions only — no store reference. Virtual children never enter
/// Bonsplit / Workspace.panels.
struct NestedSidebarSubtreeView: View, Equatable {
    let snapshot: NestedSidebarSubtreeSnapshot
    let onToggleExpansion: () -> Void
    /// Focus a nested row via the gated coordinator path (beta). Nil disables taps.
    var onFocusNode: ((NestedNodeID) -> Void)? = nil

    static func == (lhs: NestedSidebarSubtreeView, rhs: NestedSidebarSubtreeView) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: onToggleExpansion) {
                HStack(spacing: 6) {
                    Image(systemName: snapshot.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(headerTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(snapshot.isStale ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if snapshot.isStale {
                        Text(staleLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(localizedSubtreeAccessibilityLabel))
            .accessibilityIdentifier("NestedTopologySubtreeHeader")

            if snapshot.isExpanded {
                ForEach(snapshot.roots, id: \.node.id) { row in
                    NestedSidebarRowView(
                        row: row,
                        depth: 0,
                        isInteractive: snapshot.connectionState == .live && onFocusNode != nil,
                        onFocusNode: onFocusNode
                    )
                }
            }
        }
        .padding(.leading, 8)
        .accessibilityElement(children: .contain)
    }

    private var headerTitle: String {
        let base = String(localized: "sidebar.nestedTopology.header", defaultValue: "Nested")
        return "\(base) (\(snapshot.providerKind.rawValue))"
    }

    private var staleLabel: String {
        localizedConnectionState(snapshot.connectionState)
    }

    private var localizedSubtreeAccessibilityLabel: String {
        var parts: [String] = [
            String(localized: "sidebar.nestedTopology.a11y.nested", defaultValue: "Nested"),
            snapshot.providerKind.rawValue,
        ]
        if snapshot.isStale {
            parts.append(
                String(localized: "sidebar.nestedTopology.a11y.stale", defaultValue: "Stale")
            )
        }
        parts.append(localizedConnectionState(snapshot.connectionState))
        return parts.joined(separator: ", ")
    }
}

/// One nested row (workspace/tab/pane/agent) with optional children.
private struct NestedSidebarRowView: View {
    let row: NestedSidebarRowSnapshot
    let depth: Int
    let isInteractive: Bool
    let onFocusNode: ((NestedNodeID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rowLabel
                .padding(.leading, CGFloat(12 + depth * 10))
                .accessibilityLabel(Text(localizedRowAccessibilityLabel))
                .accessibilityAddTraits(rowAccessibilityTraits)
                .accessibilityIdentifier("NestedTopologyRow.\(row.node.id.rawID)")

            ForEach(row.children, id: \.node.id) { child in
                NestedSidebarRowView(
                    row: child,
                    depth: depth + 1,
                    isInteractive: isInteractive,
                    onFocusNode: onFocusNode
                )
            }
        }
    }

    @ViewBuilder
    private var rowLabel: some View {
        let content = HStack(spacing: 6) {
            Text(row.node.label.isEmpty ? row.node.id.rawID : row.node.label)
                .font(.system(size: 11))
                .foregroundStyle(row.node.stale ? .secondary : .primary)
                .lineLimit(1)
            if row.node.focused {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            if let status = row.node.agent?.status, row.node.id.kind == .agent || row.node.id.kind == .pane {
                Text(localizedAgentStatus(status))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())

        if isInteractive, let onFocusNode {
            Button {
                onFocusNode(row.node.id)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .disabled(row.node.stale)
            .accessibilityHint(Text(focusHint))
        } else {
            content
        }
    }

    private var rowAccessibilityTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = []
        if row.node.focused {
            traits.insert(.isSelected)
        }
        if isInteractive {
            traits.insert(.isButton)
        }
        return traits
    }

    private var focusHint: String {
        String(
            localized: "sidebar.nestedTopology.focusHint",
            defaultValue: "Focus nested node"
        )
    }

    private var localizedRowAccessibilityLabel: String {
        var parts = [row.node.id.kind.rawValue, row.node.label]
        if row.node.focused {
            parts.append(
                String(localized: "sidebar.nestedTopology.a11y.focused", defaultValue: "Focused")
            )
        }
        if row.node.stale || row.node.connectionState == .stale {
            parts.append(
                String(localized: "sidebar.nestedTopology.a11y.stale", defaultValue: "Stale")
            )
        } else if row.node.connectionState == .disconnected {
            parts.append(
                String(
                    localized: "sidebar.nestedTopology.a11y.disconnected",
                    defaultValue: "Disconnected"
                )
            )
        }
        if let status = row.node.agent?.status {
            parts.append(localizedAgentStatus(status))
        }
        return parts.joined(separator: ", ")
    }
}

/// Mount helper: returns a subtree view when the beta is on and a snapshot exists.
struct NestedSidebarSubtreeHost: View {
    let hostStableSurfaceID: UUID
    let snapshot: NestedSidebarSubtreeSnapshot?
    let onToggleExpansion: () -> Void
    var onFocusNode: ((NestedNodeID) -> Void)? = nil

    var body: some View {
        if NestedTopologyController.isEnabled, let snapshot {
            NestedSidebarSubtreeView(
                snapshot: snapshot,
                onToggleExpansion: onToggleExpansion,
                onFocusNode: onFocusNode
            )
            .equatable()
            .accessibilityIdentifier("NestedTopologySubtree.\(hostStableSurfaceID.uuidString)")
        }
    }
}

private func localizedConnectionState(_ state: NestedConnectionState) -> String {
    switch state {
    case .disconnected:
        return String(localized: "sidebar.nestedTopology.state.disconnected", defaultValue: "Disconnected")
    case .stale:
        return String(localized: "sidebar.nestedTopology.state.stale", defaultValue: "Stale")
    case .rejected:
        return String(localized: "sidebar.nestedTopology.state.rejected", defaultValue: "Rejected")
    case .incompatible:
        return String(localized: "sidebar.nestedTopology.state.incompatible", defaultValue: "Incompatible")
    case .connecting:
        return String(localized: "sidebar.nestedTopology.state.connecting", defaultValue: "Connecting")
    case .live:
        return String(localized: "sidebar.nestedTopology.state.live", defaultValue: "Live")
    }
}

private func localizedAgentStatus(_ status: NestedAgentStatus) -> String {
    switch status {
    case .working:
        return String(localized: "sidebar.nestedTopology.agentStatus.working", defaultValue: "Working")
    case .idle:
        return String(localized: "sidebar.nestedTopology.agentStatus.idle", defaultValue: "Idle")
    case .blocked:
        return String(localized: "sidebar.nestedTopology.agentStatus.blocked", defaultValue: "Blocked")
    case .done:
        return String(localized: "sidebar.nestedTopology.agentStatus.done", defaultValue: "Done")
    case .unknown:
        return String(localized: "sidebar.nestedTopology.agentStatus.unknown", defaultValue: "Unknown")
    }
}
