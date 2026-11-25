#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Messages on their way to the Mac (``AgentChatStore/outgoing``): each shows the moment Send is
/// tapped until the Mac has it. One with files shows its upload's progress and Stop, so a long
/// video never leaves the composer blocked with nothing to see; a text-only one is a pending bubble.
struct OutgoingMessagesView: View {
    let store: AgentChatStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.outgoing) { message in
                if message.isTextOnly {
                    PendingTextBubble(text: message.text)
                } else {
                    OutgoingMessageRow(message: message, macName: store.summary.macName) {
                        store.cancelSend(promptID: message.id)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

/// A text message the Mac has not echoed yet: it sits where the sent message will be, dimmed a
/// little, with no spinner (Leo, 2026-11-24: "they dont need to know that it's updating before
/// they KNOW it's updating"). The echo swaps in the transcript's copy; a send that fails comes
/// back to the composer with its reason (`promptNotSent`), the retry.
private struct PendingTextBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body)
                .lineLimit(6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
                .opacity(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending: \(text)")
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
