#if os(iOS)
import CmuxMobileSSH
import CmuxMobileSupport
import SwiftUI

/// Row actions for the Computers screen's SSH section. Plain closures, so no
/// store reference crosses the `List` boundary (see AGENTS.md).
struct SSHComputersSectionActions {
    let select: (UUID) -> Void
    let edit: (UUID) -> Void
    let disconnect: (UUID) -> Void
    let requestDelete: (UUID) -> Void
    let add: () -> Void
}

/// The "SSH" section of the Computers list (PRD D6): one row per saved SSH
/// computer, plus the Add SSH Computer row.
struct SSHComputersSection: View {
    let computers: [SSHComputerRowSnapshot]
    let actions: SSHComputersSectionActions

    var body: some View {
        Section {
            ForEach(computers) { computer in
                SSHComputerRow(computer: computer, actions: actions)
            }
            Button(action: actions.add) {
                Label(SSHCopy().addComputer, systemImage: "plus")
            }
            .accessibilityIdentifier("ssh.addComputer")
        } header: {
            Text(SSHCopy().sectionTitle)
        } footer: {
            Text(L10n.string(
                "mobile.ssh.section.footer",
                defaultValue: "Connect directly to any computer with an SSH server. No cmux app or account is needed on it, and these computers are saved only on this iPhone."
            ))
        }
    }
}

struct SSHComputerRow: View {
    let computer: SSHComputerRowSnapshot
    let actions: SSHComputersSectionActions

    var body: some View {
        Button {
            actions.select(computer.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(computer.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(computer.address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    SSHStatusLabel(status: computer.status)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ssh.host.\(computer.name)")
        .accessibilityHint(L10n.string(
            "mobile.ssh.row.hint",
            defaultValue: "Shows this computer's workspaces."
        ))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                actions.requestDelete(computer.id)
            } label: {
                Label(SSHCopy().delete, systemImage: "trash")
            }
            Button {
                actions.edit(computer.id)
            } label: {
                Label(SSHCopy().edit, systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            if computer.status != .idle {
                Button {
                    actions.disconnect(computer.id)
                } label: {
                    Label(SSHCopy().disconnect, systemImage: "bolt.horizontal.circle")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            Button {
                actions.edit(computer.id)
            } label: {
                Label(SSHCopy().edit, systemImage: "pencil")
            }
            if computer.status != .idle {
                Button {
                    actions.disconnect(computer.id)
                } label: {
                    Label(SSHCopy().disconnect, systemImage: "bolt.horizontal.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                actions.requestDelete(computer.id)
            } label: {
                Label(SSHCopy().delete, systemImage: "trash")
            }
        }
    }
}
#endif
