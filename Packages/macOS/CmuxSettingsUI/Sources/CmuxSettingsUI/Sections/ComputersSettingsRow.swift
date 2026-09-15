import SwiftUI

struct ComputersSettingsRow: View {
    let computer: ComputersSettingsSnapshot.Computer
    let actions: ComputersSettingsActions
    var discoveryEnabled = true
    @State private var confirmingUnpair = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(computer.isHidden ? .tertiary : .secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(computer.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .help(computer.title)
                HStack(spacing: 5) {
                    Circle()
                        .fill(computer.isConnected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(status)
                    if let tag = computer.tag {
                        Text(verbatim: "·")
                        Text(tag).lineLimit(1).help(tag)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if computer.isHidden {
                Button(String(localized: "devices.show.short", defaultValue: "Show")) {
                    Task { await actions.setHidden(computer.id, false) }
                }
                .accessibilityLabel(String(localized: "devices.show", defaultValue: "Show in My Devices"))
                .accessibilityIdentifier("SettingsComputerVisibility.\(computer.id)")
            } else if computer.isConnected {
                Button(String(localized: "settings.computers.open", defaultValue: "Open")) {
                    Task { await actions.open(computer.id) }
                }
                .disabled(!discoveryEnabled)
            }
            Menu {
                Button(computer.isHidden
                    ? String(localized: "devices.show", defaultValue: "Show in My Devices")
                    : String(localized: "devices.hide", defaultValue: "Hide from My Devices")) {
                    Task { await actions.setHidden(computer.id, !computer.isHidden) }
                }
                if computer.isPaired {
                    Divider()
                    Button(String(localized: "settings.computers.unpair", defaultValue: "Unpair"), role: .destructive) {
                        confirmingUnpair = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "devices.actions", defaultValue: "Mac options"))
            .accessibilityIdentifier("SettingsComputerOptions.\(computer.id)")
        }
        .padding(14)
        .confirmationDialog(
            String(localized: "settings.computers.unpair.confirm", defaultValue: "Unpair this Mac? Its local workspaces will not be changed."),
            isPresented: $confirmingUnpair
        ) {
            Button(String(localized: "settings.computers.unpair", defaultValue: "Unpair"), role: .destructive) {
                Task { await actions.unpair(computer.id) }
            }
        }
    }

    private var status: String {
        if computer.isHidden { return String(localized: "devices.hidden", defaultValue: "Hidden from sidebar") }
        if computer.isConnected { return String(localized: "devices.connected", defaultValue: "Connected") }
        return switch computer.isOnline {
        case true: String(localized: "settings.computers.online", defaultValue: "Online")
        case false: String(localized: "settings.computers.offline", defaultValue: "Offline")
        case nil: String(localized: "settings.computers.unknown", defaultValue: "Waiting for connection")
        }
    }
}
