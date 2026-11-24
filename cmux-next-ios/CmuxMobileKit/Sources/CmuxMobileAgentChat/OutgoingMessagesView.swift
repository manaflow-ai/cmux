#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Messages with files on their way to the Mac (``AgentChatStore/outgoing``): each shows the
/// moment Send is tapped, with its upload's progress and Stop, until the Mac has it. A long
/// video never leaves the composer blocked with nothing to see.
struct OutgoingMessagesView: View {
    let store: AgentChatStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.outgoing) { message in
                OutgoingMessageRow(message: message, macName: store.summary.macName) {
                    store.cancelSend(promptID: message.id)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct OutgoingMessageRow: View {
    let message: OutgoingMessage
    let macName: String
    let stop: () -> Void

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
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Button(action: stop) {
                Image(systemName: "stop.fill").font(.footnote.weight(.semibold)).padding(10)
            }
            .buttonStyle(.cmuxPressFillCapsule)
            .accessibilityLabel("Stop sending")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if let progress = message.progress { return progress.text(macName: macName) }
        let names = message.attachments.map(\.name)
        return "Sending \(names.count == 1 ? names[0] : "\(names.count) files")…"
    }
}
#endif
