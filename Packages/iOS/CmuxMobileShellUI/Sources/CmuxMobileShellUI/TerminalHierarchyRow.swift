import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalHierarchyRow: View {
    let snapshot: TerminalHierarchyRowSnapshot
    let select: () -> Void
    let requestClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: snapshot.isSelected ? "checkmark.circle.fill" : "terminal")
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayTitle)
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
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("MobileTerminalHierarchyRow-\(snapshot.id.rawValue)")

            if snapshot.canClose {
                Button(role: .destructive, action: requestClose) {
                    Image(systemName: "xmark.circle")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("mobile.terminal.hierarchy.close", defaultValue: "Close Terminal"))
                .accessibilityIdentifier("MobileTerminalHierarchyClose-\(snapshot.id.rawValue)")
            }
        }
        .accessibilityAction(named: L10n.string("mobile.terminal.hierarchy.switch", defaultValue: "Switch to Terminal"), select)
    }

    private var displayTitle: String {
        guard let duplicateOrdinal = snapshot.duplicateOrdinal else { return snapshot.title }
        return String(
            format: L10n.string(
                "mobile.terminal.hierarchy.duplicateTitle",
                defaultValue: "%1$@, %2$d"
            ),
            snapshot.title,
            duplicateOrdinal
        )
    }

    private var accessibilityLabel: String {
        snapshot.isSelected
            ? String(
                format: L10n.string(
                    "mobile.terminal.hierarchy.activeLabel",
                    defaultValue: "%@, active terminal"
                ),
                displayTitle
            )
            : displayTitle
    }
}
