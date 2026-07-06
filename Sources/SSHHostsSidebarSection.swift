import CmuxFoundation
import SwiftUI

/// Immutable per-host snapshot rendered by ``SSHHostsSidebarSection``.
///
/// Value-only by design: rows below the sidebar's lazy list boundary receive
/// snapshots plus closures, never observable stores (see the sidebar
/// snapshot-boundary rule / issue #2586).
struct SSHHostsSidebarItem: Equatable, Identifiable {
    let alias: String
    /// Whether this window already has a live (connected or connecting)
    /// remote workspace for the alias.
    let isActive: Bool

    var id: String { alias }
}

/// Closure bundle for ``SSHHostsSidebarSection``; kept out of the row views'
/// `Equatable` comparisons (closures are assumed stable across renders).
struct SSHHostsSidebarSectionActions {
    let toggleCollapsed: () -> Void
    let connect: (String) -> Void
}

/// Collapsible "SSH Hosts" sidebar section listing the concrete host aliases
/// from the user's SSH config. Clicking a host connects it as a remote SSH
/// workspace (or selects the window's existing live workspace for it).
struct SSHHostsSidebarSection: View, Equatable {
    let items: [SSHHostsSidebarItem]
    let isCollapsed: Bool
    let actions: SSHHostsSidebarSectionActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.isCollapsed == rhs.isCollapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if !isCollapsed {
                // Lazy: a generated/corporate config can declare hundreds of
                // aliases, and this sits in the sidebar's scroll hot path.
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        SSHHostsSidebarHostRow(item: item, connect: actions.connect)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityIdentifier("SSHHostsSidebarSection")
    }

    private var header: some View {
        Button(action: actions.toggleCollapsed) {
            HStack(spacing: 7) {
                Text(String(localized: "sidebar.sshHosts.sectionTitle", defaultValue: "SSH Hosts"))
                    .cmuxFont(size: 12, weight: .regular)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundColor(.secondary.opacity(0.6))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(String(localized: "sidebar.sshHosts.toggleSection", defaultValue: "Toggle SSH Hosts section"))
        .accessibilityIdentifier("SSHHostsSidebarSectionHeader")
    }
}

/// One clickable host row. `Equatable` on its value snapshot so unrelated
/// sidebar churn skips its body.
private struct SSHHostsSidebarHostRow: View, Equatable {
    let item: SSHHostsSidebarItem
    let connect: (String) -> Void

    @State private var isHovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        Button {
            connect(item.alias)
        } label: {
            HStack(spacing: 6) {
                CmuxSystemSymbolImage(magnified: "server.rack", pointSize: 10, weight: .regular)
                    .foregroundColor(.secondary.opacity(0.8))

                Text(item.alias)
                    .cmuxFont(size: 12.5)
                    .foregroundColor(.primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if item.isActive {
                    Circle()
                        .fill(Color.green.opacity(0.85))
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(String(localized: "remote.status.connected", defaultValue: "Connected"))
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .safeHelp(
            String.localizedStringWithFormat(
                String(localized: "sidebar.sshHosts.connectHelp", defaultValue: "Connect to %@ over SSH"),
                item.alias
            )
        )
        .accessibilityIdentifier("SSHHostsSidebarRow.\(item.alias)")
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isHovered {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.05))
                .padding(.horizontal, 8)
        }
    }
}
