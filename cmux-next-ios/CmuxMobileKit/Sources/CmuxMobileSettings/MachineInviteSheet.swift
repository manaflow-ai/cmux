#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// Pair Another Machine, from the phone: the code a Mac's invite QR carries
/// (`https://cmux.com/pair?i=…`, ``MachineInvite``), filled in, with the one
/// line the new machine runs and the install line for one without cmux, each
/// ready to copy (Universal Clipboard pastes it on a Mac nearby) or share. The
/// new machine redeems it; the Mac that made it confirms the machine when its
/// four words match. Opened by the Camera's link and by Settings → Devices →
/// Scan QR on your Mac.
public struct MachineInviteSheet: View {
    let invite: MachineInvite
    /// Closes the sheet; nil inside a sheet that has its own Cancel (the scanner).
    let done: (() -> Void)?
    @State private var copied: String?

    public init(invite: MachineInvite, done: (() -> Void)? = nil) {
        self.invite = invite
        self.done = done
    }

    public var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Text(invite.display)
                        .font(theme.type.codeDigit)
                        .accessibilityIdentifier("machineInvite.code")
                    Text("Your Mac made this code for a new machine. It works once, for 10 minutes.")
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.label2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                copyRow("Copy Code", text: invite.code, id: "machineInvite.copyCode")
            }
            Section {
                command(invite.line, id: "machineInvite.line")
                copyRow("Copy Command", text: invite.line, id: "machineInvite.copyLine")
            } header: {
                Text("On the new machine, run")
            }
            Section {
                command(invite.installLine, id: "machineInvite.installLine")
                copyRow("Copy Install Command", text: invite.installLine, id: "machineInvite.copyInstall")
            } header: {
                Text("No cmux on it yet")
            } footer: {
                Text("Then confirm the new machine on your Mac when its four words match.")
            }
        }
        .navigationTitle("Pair Another Machine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: invite.line)
                    .accessibilityIdentifier("machineInvite.share")
            }
            if let done {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done).accessibilityIdentifier("machineInvite.done")
                }
            }
        }
    }

    private func command(_ text: String, id: String) -> some View {
        Text(text)
            .font(theme.type.codeBody)
            .accessibilityIdentifier(id)
    }

    private func copyRow(_ title: LocalizedStringKey, text: String, id: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            theme.haptics.success()
            copied = id
        } label: {
            Label(copied == id ? "Copied" : title, systemImage: copied == id ? "checkmark" : "doc.on.doc")
        }
        .accessibilityIdentifier(id)
    }
}
#endif
