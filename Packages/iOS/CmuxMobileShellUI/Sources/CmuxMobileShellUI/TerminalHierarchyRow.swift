import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalHierarchyRow: View {
    let snapshot: TerminalHierarchyRowSnapshot
    let select: () -> Void
    let requestClose: () -> Void
    let moveEarlier: (() -> Void)?
    let moveLater: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: snapshot.isSelected ? "checkmark.circle.fill" : "terminal")
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.displayTitle)
                            .lineLimit(2)
                        if snapshot.isSelected {
                            Text(L10n.string("mobile.terminal.hierarchy.active", defaultValue: "Active"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !snapshot.isReady {
                            Text(L10n.string("mobile.terminal.hierarchy.starting", defaultValue: "Starting…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.accessibilityLabel)
            .accessibilityIdentifier("MobileTerminalHierarchyRow-\(snapshot.id.rawValue)")

            if snapshot.canClose {
                Button(role: .destructive, action: requestClose) {
                    Image(systemName: "xmark.circle")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(snapshot.closeAccessibilityLabel)
                .accessibilityIdentifier("MobileTerminalHierarchyClose-\(snapshot.id.rawValue)")
            }
        }
        .accessibilityAction(named: L10n.string("mobile.terminal.hierarchy.switch", defaultValue: "Switch to Terminal"), select)
        .accessibilityActions {
            if let moveEarlier {
                Button(
                    L10n.string("mobile.terminal.hierarchy.moveEarlier", defaultValue: "Move Terminal Earlier"),
                    action: moveEarlier
                )
            }
            if let moveLater {
                Button(
                    L10n.string("mobile.terminal.hierarchy.moveLater", defaultValue: "Move Terminal Later"),
                    action: moveLater
                )
            }
            if snapshot.canClose {
                Button(snapshot.closeAccessibilityLabel, role: .destructive, action: requestClose)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if snapshot.canClose {
                Button(role: .destructive, action: requestClose) {
                    Label(snapshot.closeAccessibilityLabel, systemImage: "trash")
                }
                .accessibilityIdentifier("MobileTerminalHierarchySwipeClose-\(snapshot.id.rawValue)")
            }
        }
    }
}
