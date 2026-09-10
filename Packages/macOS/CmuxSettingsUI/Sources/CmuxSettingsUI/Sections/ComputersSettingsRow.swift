import SwiftUI

struct ComputersSettingsRow: View {
    let computer: ComputersSettingsSnapshot.Computer
    let actions: ComputersSettingsActions
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
            if computer.isPaired {
                Button(String(localized: "settings.computers.open", defaultValue: "Open")) {
                    Task { await actions.open(computer.id) }
                }
                Button(String(localized: "settings.computers.unpair", defaultValue: "Unpair"), role: .destructive) {
                    confirmingUnpair = true
                }
            } else {
                Text(String(localized: "settings.computers.notPaired", defaultValue: "Not paired"))
                    .foregroundStyle(.secondary)
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
        switch computer.isOnline {
        case true: String(localized: "settings.computers.online", defaultValue: "Online")
        case false: String(localized: "settings.computers.offline", defaultValue: "Offline")
        case nil: String(localized: "settings.computers.unknown", defaultValue: "Presence unknown")
        }
    }
}
