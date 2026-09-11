import SwiftUI

struct ComputersSettingsRow: View {
    let computer: ComputersSettingsSnapshot.Computer
    let actions: ComputersSettingsActions
    var discoveryEnabled = true
    @State private var confirmingUnpair = false

    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer")
            VStack(alignment: .leading) {
                Text(computer.title)
                if let tag = computer.tag { Text(tag).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(status).foregroundStyle(.secondary)
            Button(computer.isHidden
                ? String(localized: "devices.show", defaultValue: "Show in My Devices")
                : String(localized: "devices.hide", defaultValue: "Hide from My Devices")) {
                Task { await actions.setHidden(computer.id, !computer.isHidden) }
            }
            .accessibilityIdentifier("SettingsComputerVisibility.\(computer.id)")
            if computer.isPaired || computer.isConnected {
                Button(String(localized: "settings.computers.open", defaultValue: "Open")) {
                    Task { await actions.open(computer.id) }
                }
                .disabled(!discoveryEnabled)
            }
            if computer.isPaired {
                Button(String(localized: "settings.computers.unpair", defaultValue: "Unpair"), role: .destructive) {
                    confirmingUnpair = true
                }
            }
        }
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
        if computer.isConnected { return String(localized: "devices.connected", defaultValue: "Connected") }
        return switch computer.isOnline {
        case true: String(localized: "settings.computers.online", defaultValue: "Online")
        case false: String(localized: "settings.computers.offline", defaultValue: "Offline")
        case nil: String(localized: "settings.computers.unknown", defaultValue: "Presence unknown")
        }
    }
}
