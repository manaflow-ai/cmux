import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI

/// The pane card shown after someone disconnected this Mac from a Cloud
/// terminal. The session does not reconnect by itself; the user reattaches.
struct TerminalSharingDetachedCard: View {
    let detachment: TerminalSharingDetachment
    let onReattach: (Bool) -> Void

    private var message: String {
        let time = detachment.at.formatted(date: .omitted, time: .shortened)
        switch detachment.reason {
        case let .disconnectedBy(actor):
            let who = actor.map(Self.actorLabel) ?? String(
                localized: "terminalSharing.detached.someone",
                defaultValue: "Someone"
            )
            return String(
                format: String(
                    localized: "terminalSharing.detached.byMessageShort",
                    defaultValue: "%1$@ disconnected this Mac at %2$@."
                ),
                who, time
            )
        case .hostShutdown:
            return String(
                format: String(localized: "terminalSharing.detached.hostShutdown", defaultValue: "The terminal host shut down at %@."),
                time
            )
        case .superseded:
            return String(
                format: String(localized: "terminalSharing.detached.superseded", defaultValue: "Another window of this Mac replaced this one at %@."),
                time
            )
        case .network:
            return String(localized: "terminalSharing.detached.network", defaultValue: "The network dropped.")
        }
    }

    private static func actorLabel(_ actor: TerminalDetachActor) -> String {
        let name = actor.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = actor.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name?.isEmpty == false ? name : nil, device?.isEmpty == false ? device : nil) {
        case let (name?, device?):
            return String(
                format: String(localized: "terminalSharing.participant.personDevice", defaultValue: "%1$@ · %2$@"),
                name, device
            )
        case let (name?, nil): return name
        case let (nil, device?): return device
        case (nil, nil):
            return String(localized: "terminalSharing.detached.someone", defaultValue: "Someone")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "terminalSharing.detached.titleShort", defaultValue: "Detached"))
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(String(localized: "terminalSharing.detached.reattach", defaultValue: "Reattach")) {
                    onReattach(false)
                }
                .keyboardShortcut(.defaultAction)
                Button(String(localized: "terminalSharing.detached.reattachAsViewer", defaultValue: "Reattach as Viewer")) {
                    onReattach(true)
                }
                .buttonStyle(.link)
                .help(String(localized: "terminalSharing.detached.reattachAsViewer.help", defaultValue: "Reattach without changing the terminal size"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}
