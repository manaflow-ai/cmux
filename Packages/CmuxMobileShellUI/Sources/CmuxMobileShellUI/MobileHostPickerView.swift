#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Lets the user switch which paired Mac this device controls, and pair another.
///
/// Lists every Mac paired with this device (from the on-device store), marks the
/// one the live connection targets, switches on tap, forgets on swipe, and pairs
/// a new Mac by scanning its QR code without dropping the others.
struct MobileHostPickerView: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.pairedMacs.isEmpty {
                        Text(L10n.string("mobile.hostPicker.empty", defaultValue: "No paired Macs yet."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.pairedMacs) { mac in
                        macRow(mac)
                    }
                } header: {
                    Text(L10n.string("mobile.hostPicker.header", defaultValue: "Paired Macs"))
                } footer: {
                    Text(L10n.string(
                        "mobile.hostPicker.footer",
                        defaultValue: "Switch which Mac this device controls. Pairing another Mac keeps the others, so you can hop between them."
                    ))
                }

                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label(
                            L10n.string("mobile.hostPicker.addMac", defaultValue: "Pair Another Mac"),
                            systemImage: "plus"
                        )
                    }
                    .accessibilityIdentifier("MobileHostPickerAddMac")
                }
            }
            .navigationTitle(L10n.string("mobile.hostPicker.title", defaultValue: "Switch Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileHostPickerDone")
                }
            }
            .task { await store.loadPairedMacs() }
            .sheet(isPresented: $showingScanner) {
                MobilePairingScannerSheet { code in
                    showingScanner = false
                    Task {
                        // Pair without dropping the current session on a bad scan:
                        // dismiss only when the new Mac actually connected.
                        if await store.pairAdditionalMac(code) {
                            dismiss()
                        } else {
                            await store.loadPairedMacs()
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("MobileHostPicker")
    }

    @ViewBuilder
    private func macRow(_ mac: MobilePairedMac) -> some View {
        let isActive = mac.isActive
        Button {
            Task { await store.switchToMac(macDeviceID: mac.macDeviceID) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.displayName ?? mac.macDeviceID)
                        .foregroundStyle(.primary)
                    Text(mac.lastSeenAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(L10n.string("mobile.hostPicker.active", defaultValue: "Active"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileHostPickerRow-\(mac.macDeviceID)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await store.forgetMac(macDeviceID: mac.macDeviceID) }
            } label: {
                Label(L10n.string("mobile.hostPicker.forget", defaultValue: "Forget"), systemImage: "trash")
            }
            .accessibilityIdentifier("MobileHostPickerForget-\(mac.macDeviceID)")
        }
    }
}
#endif
