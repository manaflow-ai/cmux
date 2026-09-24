#if os(iOS)
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI

// Value snapshots and user-facing copy for SSH computers
// (docs/prd/ios-direct-ssh.md). Nothing here holds an `@Observable` store, so
// the rows that consume these sit safely below `List`/`ForEach` boundaries.

/// One saved SSH computer as the Computers list shows it.
struct SSHComputerRowSnapshot: Equatable, Identifiable {
    let id: UUID
    let name: String
    /// `user@host:port` (port omitted when 22).
    let address: String
    let status: MobileSSHHostStatus
    let persistence: SSHPersistenceMode?

    init(host: SSHHostRecord, status: MobileSSHHostStatus) {
        id = host.id
        name = host.name
        address = host.endpoint.sshDisplayAddress
        self.status = status
        persistence = host.persistence
    }

    /// Builds the SSH section's rows from the live SSH runtime.
    @MainActor
    static func snapshots(from computers: MobileSSHComputers) -> [SSHComputerRowSnapshot] {
        computers.hosts.map { host in
            SSHComputerRowSnapshot(host: host, status: computers.statusByHost[host.id] ?? .idle)
        }
    }
}

extension SSHEndpoint {
    /// `user@host` plus `:port` when it is not 22; IPv6 literals are bracketed
    /// when a port follows so the address stays unambiguous.
    var sshDisplayAddress: String {
        let hostPart = port != 22 && host.contains(":") ? "[\(host)]" : host
        let base = username.isEmpty ? hostPart : "\(username)@\(hostPart)"
        return port == 22 ? base : "\(base):\(port)"
    }
}

extension MobileSSHHostStatus {
    var sshStatusText: String {
        switch self {
        case .idle:
            L10n.string("mobile.ssh.status.idle", defaultValue: "Not connected")
        case .connecting:
            L10n.string("mobile.ssh.status.connecting", defaultValue: "Connecting…")
        case .connected:
            L10n.string("mobile.ssh.status.connected", defaultValue: "Connected")
        case .failed(let message):
            message
        }
    }

    var sshStatusColor: Color {
        switch self {
        case .idle: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension SSHPersistenceMode {
    /// Display order for pickers: recommended first, "coming soon" last.
    static let sshPickerOrder: [SSHPersistenceMode] = [.cmuxTUI, .tmux, .plain, .eternalTerminal, .mosh]

    var sshDisplayName: String {
        switch self {
        case .cmuxTUI:
            L10n.string("mobile.ssh.persistence.cmuxTUI.name", defaultValue: "cmux-tui")
        case .tmux:
            L10n.string("mobile.ssh.persistence.tmux.name", defaultValue: "tmux")
        case .plain:
            L10n.string("mobile.ssh.persistence.plain.name", defaultValue: "Plain Shell")
        case .eternalTerminal:
            L10n.string("mobile.ssh.persistence.et.name", defaultValue: "Eternal Terminal")
        case .mosh:
            L10n.string("mobile.ssh.persistence.mosh.name", defaultValue: "mosh")
        }
    }

    var sshDescription: String {
        switch self {
        case .cmuxTUI:
            L10n.string(
                "mobile.ssh.persistence.cmuxTUI.description",
                defaultValue: "Sessions keep running after you leave and reopen exactly as you left them. cmux installs its terminal helper, cmux-tui, in ~/.local/bin on first use."
            )
        case .tmux:
            L10n.string(
                "mobile.ssh.persistence.tmux.description",
                defaultValue: "Sessions keep running in tmux on the computer. Requires tmux to be installed there."
            )
        case .plain:
            L10n.string(
                "mobile.ssh.persistence.plain.description",
                defaultValue: "A normal login shell. Sessions end when you leave the app or lose the connection."
            )
        case .eternalTerminal:
            L10n.string(
                "mobile.ssh.persistence.et.description",
                defaultValue: "Survives network changes. Requires etserver on the computer."
            )
        case .mosh:
            L10n.string(
                "mobile.ssh.persistence.mosh.description",
                defaultValue: "Survives network changes and sleep, with instant typing feedback. Requires mosh-server on the computer."
            )
        }
    }

    var sshAccessibilityKey: String {
        switch self {
        case .cmuxTUI: "cmuxTUI"
        case .tmux: "tmux"
        case .plain: "plain"
        case .eternalTerminal: "eternalTerminal"
        case .mosh: "mosh"
        }
    }
}

extension SSHIdleClosePolicy {
    var sshDisplayName: String {
        switch self {
        case .oneHour:
            L10n.string("mobile.ssh.idleClose.oneHour", defaultValue: "1 Hour")
        case .oneDay:
            L10n.string("mobile.ssh.idleClose.oneDay", defaultValue: "24 Hours")
        case .sevenDays:
            L10n.string("mobile.ssh.idleClose.sevenDays", defaultValue: "7 Days")
        case .never:
            L10n.string("mobile.ssh.idleClose.never", defaultValue: "Never")
        }
    }
}

enum SSHCopy {
    static var sectionTitle: String {
        L10n.string("mobile.ssh.section.title", defaultValue: "SSH")
    }
    static var addComputer: String {
        L10n.string("mobile.ssh.addComputer", defaultValue: "Add SSH Computer")
    }
    static var addComputerEllipsis: String {
        L10n.string("mobile.ssh.addComputer.menu", defaultValue: "Add SSH Computer…")
    }
    static var pairMacEllipsis: String {
        L10n.string("mobile.ssh.pairMac.menu", defaultValue: "Pair a Mac…")
    }
    static var edit: String {
        L10n.string("mobile.ssh.action.edit", defaultValue: "Edit")
    }
    static var disconnect: String {
        L10n.string("mobile.ssh.action.disconnect", defaultValue: "Disconnect")
    }
    static var delete: String {
        L10n.string("mobile.ssh.action.delete", defaultValue: "Delete")
    }
    static var cancel: String {
        L10n.string("mobile.ssh.action.cancel", defaultValue: "Cancel")
    }
    static var copy: String {
        L10n.string("mobile.ssh.action.copy", defaultValue: "Copy")
    }
    static var recommended: String {
        L10n.string("mobile.ssh.persistence.recommended", defaultValue: "Recommended")
    }
    static var comingSoon: String {
        L10n.string("mobile.ssh.persistence.comingSoon", defaultValue: "Coming soon")
    }
    static var askOnFirstConnect: String {
        L10n.string("mobile.ssh.persistence.ask", defaultValue: "Ask on First Connect")
    }
    static var keysTitle: String {
        L10n.string("mobile.ssh.keys.title", defaultValue: "SSH Keys")
    }
    static var deleteHostTitle: String {
        L10n.string("mobile.ssh.delete.title", defaultValue: "Delete this SSH computer?")
    }
    static var deleteHostMessage: String {
        L10n.string(
            "mobile.ssh.delete.message",
            defaultValue: "Its settings are removed from this iPhone. Sessions already running on the computer keep running."
        )
    }
}

/// A small colored dot plus the status text, shared by the Computers row and
/// the workspace list's SSH status banner.
struct SSHStatusLabel: View {
    let status: MobileSSHHostStatus

    var body: some View {
        HStack(spacing: 6) {
            if status == .connecting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(status.sshStatusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(status.sshStatusText)
                .lineLimit(2)
        }
        .font(.footnote)
        .foregroundStyle(status.isFailed ? Color.red : Color.secondary)
    }
}
#endif
