#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// What a Feed compose sheet answers: a free-text terminal reply to a
/// finished turn, a question's "Other…" answer, or exit-plan revise feedback.
struct AgentFeedComposeContext: Identifiable {
    enum Kind {
        case terminalReply
        case questionOther
        case planRevise
    }

    let item: MobileAgentFeedItem
    let kind: Kind

    var id: String {
        "\(item.id.macDeviceID)|\(item.id.macInstanceTag ?? "")|\(item.id.itemID)|\(kind)"
    }
}

/// The X-style reply composer: a sheet quoting the message being replied to
/// above the editor, Cancel on the top left, a prominent Reply button on the
/// top right, and a thread line connecting the quote to the draft. The Feed
/// timeline itself never hosts a keyboard; it lives and dies with this sheet
/// (post, Cancel, or swipe-down all dismiss it).
struct AgentFeedReplyComposer: View {
    let context: AgentFeedComposeContext
    let actions: AgentFeedActions
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    private var model: AgentFeedRowModel { AgentFeedRowModel(item: context.item) }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    quotedMessage
                    draftRow
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(
                        localized: "mobile.agentFeed.compose.cancel",
                        defaultValue: "Cancel",
                        bundle: .module
                    )) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        send()
                    } label: {
                        Text(sendLabel)
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    trimmedDraft.isEmpty
                                        ? Color.accentColor.opacity(0.4)
                                        : Color.accentColor
                                )
                            )
                            .foregroundStyle(.white)
                    }
                    .disabled(trimmedDraft.isEmpty)
                    .accessibilityIdentifier("MobileAgentFeedComposeSend")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// The referenced message, rendered like X's quoted parent post: avatar,
    /// author, snippet, and a thread line down to the draft row.
    private var quotedMessage: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 40, height: 40)
                    TaskTemplateIcon(value: model.presentation.authorIconValue, size: 22)
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 2)
                    .frame(minHeight: 18)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(model.presentation.authorName)
                        .font(.subheadline.weight(.semibold))
                    Text(model.presentation.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let output = model.presentation.outputText {
                    Text(output)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
                Text(replyingToLine)
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var draftRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $draft, axis: .vertical)
                .font(.body)
                .lineLimit(3...12)
                .focused($editorFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.top, 8)
        }
        .task {
            editorFocused = true
        }
    }

    private var replyingToLine: String {
        String(
            localized: "mobile.agentFeed.compose.replyingTo",
            defaultValue: "Replying to \(model.presentation.authorName)",
            bundle: .module
        )
    }

    private var sendLabel: String {
        switch context.kind {
        case .terminalReply:
            return String(
                localized: "mobile.agentFeed.compose.reply",
                defaultValue: "Reply",
                bundle: .module
            )
        case .questionOther, .planRevise:
            return String(
                localized: "mobile.agentFeed.question.send",
                defaultValue: "Send",
                bundle: .module
            )
        }
    }

    private var placeholder: String {
        switch context.kind {
        case .terminalReply:
            return String(
                localized: "mobile.agentFeed.reply.placeholder",
                defaultValue: "Reply to agent…",
                bundle: .module
            )
        case .questionOther:
            return String(
                localized: "mobile.agentFeed.question.otherPlaceholder",
                defaultValue: "Your answer",
                bundle: .module
            )
        case .planRevise:
            return String(
                localized: "mobile.agentFeed.exitPlan.revisePlaceholder",
                defaultValue: "What should change?",
                bundle: .module
            )
        }
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        switch context.kind {
        case .terminalReply:
            actions.terminalReply(context.item, text)
        case .questionOther:
            actions.questionReply(context.item, [text])
        case .planRevise:
            actions.exitPlanReply(context.item, "manual", text)
        }
        dismiss()
    }
}
#endif
