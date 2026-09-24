#if os(iOS)
import CmuxMobileSSH
import CmuxMobileSupport
import SwiftUI

/// One persistence mode as a selectable row: name, Recommended / Coming soon
/// badge, one-line description, optional unavailability note, and a checkmark.
/// Value-only (PRD D9/D15), shared by the host form and the first-connect prompt.
struct SSHPersistenceOptionRow: View {
    let mode: SSHPersistenceMode
    let isSelected: Bool
    /// Extra reason this host cannot use the mode (e.g. tmux is missing).
    var unavailableReason: String? = nil
    let select: () -> Void

    private var isEnabled: Bool {
        mode.isAvailable && unavailableReason == nil
    }

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(mode.sshDisplayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                        if mode == .cmuxTUI {
                            badge(SSHCopy.recommended, tint: .accentColor)
                        } else if !mode.isAvailable {
                            badge(SSHCopy.comingSoon, tint: .secondary)
                        }
                    }
                    Text(mode.sshDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let unavailableReason {
                        Text(unavailableReason)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("ssh.persistence.\(mode.sshAccessibilityKey)")
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// The host form's "Keep sessions alive" chooser: every mode plus "Ask on
/// first connect" (a `nil` choice).
struct SSHPersistenceChoiceView: View {
    @Binding var selection: SSHPersistenceMode?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SSHCopy.askOnFirstConnect)
                                .font(.body.weight(.semibold))
                            Text(L10n.string(
                                "mobile.ssh.persistence.ask.description",
                                defaultValue: "cmux checks what the computer supports and asks the first time you connect."
                            ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if selection == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ssh.persistence.ask")
            }
            Section {
                ForEach(SSHPersistenceMode.sshPickerOrder, id: \.self) { mode in
                    SSHPersistenceOptionRow(mode: mode, isSelected: selection == mode) {
                        selection = mode
                        dismiss()
                    }
                }
            } footer: {
                Text(L10n.string(
                    "mobile.ssh.persistence.footer",
                    defaultValue: "Persistent sessions keep programs running on the computer when iOS suspends the app or the network drops."
                ))
            }
        }
        .navigationTitle(L10n.string("mobile.ssh.persistence.title", defaultValue: "Keep Sessions Alive"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
