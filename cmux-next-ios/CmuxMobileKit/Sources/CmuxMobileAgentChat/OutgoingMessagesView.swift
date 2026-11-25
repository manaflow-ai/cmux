#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Messages on their way to the Mac (``AgentChatStore/outgoing``): one with files from the moment
/// Send is tapped, with its upload's progress; a text one once it waits (the link, a retry). Each
/// has an exit at every stage (Leo 2026-11-24: "i also couldnt cancel out of the send. i need to
/// be able to do that otherwise i cant edit or anything to retry or delete and remove"): Stop
/// and Edit bring it back to the composer, Delete drops it, Send now skips a retry's wait. What
/// each row offers is the Rust outbox's (`pending_sends`); this only draws it.
struct OutgoingMessagesView: View {
    let store: AgentChatStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.outgoing) { message in
                OutgoingMessageRow(
                    message: message, macName: store.summary.macName,
                    stop: { store.cancelSend(promptID: message.id) },
                    delete: { store.deleteSend(promptID: message.id) },
                    sendNow: { store.retrySend(promptID: message.id) }
                )
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct OutgoingMessageRow: View {
    let message: OutgoingMessage
    let macName: String
    let stop: () -> Void
    let delete: () -> Void
    let sendNow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text).font(.subheadline).lineLimit(2)
                }
                Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.numericText())
                if let progress = message.progress, progress.phase == .sending {
                    ProgressView(value: progress.fraction).progressViewStyle(.linear)
                } else if !message.attachments.isEmpty || message.stopping {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if message.canSendNow {
                    Button("Send Now", systemImage: "arrow.clockwise", action: sendNow)
                }
                Button("Edit", systemImage: "pencil", action: stop)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).padding(10)
            }
            .accessibilityLabel("More for this message")
            .disabled(message.stopping)
            Button(action: stop) {
                Image(systemName: "stop.fill").font(.footnote.weight(.semibold)).padding(10)
            }
            .buttonStyle(.cmuxPressFillCapsule)
            .accessibilityLabel("Stop sending")
            .disabled(message.stopping)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var status: String {
        if message.stopping { return "Stopping…" }
        if let progress = message.progress { return progress.text(macName: macName) }
        if message.attachments.isEmpty { return "Waiting for \(macName)…" }
        let names = message.attachments.map(\.name)
        return "Sending \(names.count == 1 ? names[0] : "\(names.count) files")…"
    }
}
#endif
