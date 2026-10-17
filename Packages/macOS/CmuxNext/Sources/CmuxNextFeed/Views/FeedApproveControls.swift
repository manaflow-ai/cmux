import AppKit
import CmuxNextIcons
import SwiftUI

/// `approve`: scope (when the poster offers more than one), Deny, Allow.
struct FeedApproveControls: View {
    let item: FeedItem
    let prompt: FeedPrompt.Approve
    let model: FeedModel
    var density: FeedDensity
    @Environment(\.feedColors) private var colors

    private var scope: FeedApproveScope { model.drafts.scopes[item.id] ?? prompt.scopes.first ?? .once }

    var body: some View {
        if density == .detail {
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.action.summary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let risk = prompt.action.risk, !risk.isEmpty {
                        Text(risk)
                            .font(.system(size: 11))
                            .foregroundStyle(colors.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                controls
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(colors.hover))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(colors.borders ? colors.separator : .clear, lineWidth: 1))
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if prompt.scopes.count > 1 && density != .menubar {
                Menu {
                    ForEach(prompt.scopes, id: \.self) { option in
                        Button(FeedStrings.scope(option)) { model.drafts.scopes[item.id] = option }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(FeedStrings.scope(scope))
                        // Menu labels render through AppKit, which keeps images but not canvases.
                        Image(nsImage: .icon(.controlPopup, size: .iconFloor)).renderingMode(.template)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 4)
            }
            Button(FeedStrings.deny) { model.answer(item.id, .approve(.init(.deny))) }
                .buttonStyle(FeedButtonStyle(role: .plain, compact: density == .menubar))
            Button(FeedStrings.allow) { model.answer(item.id, .approve(.init(.allow, scope: scope))) }
                .buttonStyle(FeedButtonStyle(role: .primary, compact: density == .menubar))
        }
    }
}

/// `review`: an optional comment (detail), Request Changes, Approve.
struct FeedReviewControls: View {
    let item: FeedItem
    let model: FeedModel
    var density: FeedDensity

    private var comment: Binding<String> {
        Binding(get: { model.drafts.replies[item.id] ?? "" }, set: { model.drafts.replies[item.id] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if density == .detail {
                FeedTextField(placeholder: FeedStrings.reply, text: comment)
            }
            HStack(spacing: 6) {
                if density != .menubar {
                    Button(FeedStrings.requestChanges) { send(.requestChanges) }
                        .buttonStyle(FeedButtonStyle(role: .plain))
                }
                Button(FeedStrings.approve) { send(.approve) }
                    .buttonStyle(FeedButtonStyle(role: .primary, compact: density == .menubar))
            }
        }
    }

    private func send(_ verdict: FeedAnswerValue.Verdict) {
        let text = comment.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.answer(item.id, .review(verdict, comment: text.isEmpty ? nil : text))
    }
}
