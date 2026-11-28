#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Messages on their way to the Mac (``AgentChatStore/outgoing``): each shows the moment Send is
/// tapped until the Mac has it (Leo, 2026-11-24: "i think we can maybe be more optimistic
/// sometimes. it is a bit slow on ios."). A text one is a quiet pending bubble until it waits (the
/// link, a retry); one with files, or one that waits, is a row with its exits at every stage (Leo
/// 2026-11-24: "i also couldnt cancel out of the send. i need to be able to do that otherwise i
/// cant edit or anything to retry or delete and remove"): Stop and Edit bring it back to the
/// composer, Delete drops it, Send now skips a retry's wait. What each row offers is the Rust
/// outbox's (`pending_sends`); this only draws it.
struct OutgoingMessagesView: View {
    let store: AgentChatStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.outgoing) { message in
                if message.isQuietPending {
                    PendingTextBubble(text: message.text)
                } else {
                    OutgoingMessageRow(
                        message: message, macName: store.summary.macName,
                        stop: { store.cancelSend(promptID: message.id) },
                        delete: { store.deleteSend(promptID: message.id) },
                        sendNow: { store.retrySend(promptID: message.id) }
                    )
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

/// A text message the Mac has not echoed yet: it sits where the sent message will be, dimmed a
/// little, with no spinner (Leo, 2026-11-24: "they dont need to know that it's updating before
/// they KNOW it's updating"). The echo swaps in the transcript's copy; one that waits past the
/// outbox's quiet threshold becomes a row with Stop, Edit, Delete and Send now.
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
        #if DEBUG
        // The send trace's tap-to-bubble mark (OptimisticSendCaptureUITests).
        .onAppear { LoadFrameProbe.shared?.event("pending-bubble") }
        #endif
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
