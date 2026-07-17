import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct StopActionArea: View {
    @Binding var draft: FeedStopDraft
    @Binding var focusRequest: Int

    let placement: FeedPlacement
    let focusScopeID: UUID
    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let onSend: (String) -> Void

    private var trimmed: String {
        draft.reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool { !trimmed.isEmpty }
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent
    private var replyFont: NSFont { GlobalFontMagnification.systemFont(ofSize: 12) }
    private var replyBinding: Binding<String> {
        Binding(
            get: { draft.reply },
            set: { draft.reply = $0 }
        )
    }

    var body: some View {
        let _ = globalFontPercent
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .cmuxFont(size: 10)
                    .foregroundColor(.secondary)
                Text(String(localized: "feed.stop.label", defaultValue: "Claude finished — reply to continue"))
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
            }
            FeedInlineTextField(
                text: replyBinding,
                focusRequest: focusRequest == 0 ? nil : focusRequest,
                placeholder: String(localized: "feed.stop.placeholder", defaultValue: "Reply to Claude…"),
                isEnabled: true,
                font: replyFont,
                placement: placement,
                focusScopeID: focusScopeID,
                onFocus: onFocusRow,
                onBlur: onBlurRow,
                onSubmit: sendReply
            )
            .frame(
                maxWidth: .infinity,
                minHeight: FeedInlineTextEditorView.minimumHeight(for: replyFont),
                alignment: .leading
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(canSend ? 0.25 : 0.10), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onFocusRow()
                requestReplyFocus()
            }
            FeedButton(
                label: String(localized: "feed.stop.send", defaultValue: "Send to Claude"),
                leadingIcon: "arrow.up.circle.fill",
                kind: canSend ? .primary : .soft,
                size: .medium,
                fullWidth: true,
                dimmed: !canSend
            ) {
                guard canSend else { return }
                onActionRow()
                sendReply()
            }
        }
    }

    private func requestReplyFocus() {
        focusRequest += 1
    }

    private func sendReply() {
        guard canSend else { return }
        onSend(trimmed)
        draft.reply = ""
    }
}

extension WorkstreamKind {
    var symbolName: String {
        switch self {
        case .permissionRequest: return "lock.shield"
        case .exitPlan: return "list.bullet.rectangle"
        case .question: return "questionmark.circle"
        case .toolUse, .toolResult: return "terminal"
        case .userPrompt: return "person"
        case .assistantMessage: return "sparkles"
        case .sessionStart, .sessionEnd: return "play.circle"
        case .stop: return "stop.circle"
        case .todos: return "checklist"
        }
    }
}
