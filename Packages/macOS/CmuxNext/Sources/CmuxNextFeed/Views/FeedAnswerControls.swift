import SwiftUI

/// How much room the answer controls get.
enum FeedDensity {
    /// One line in the menu bar popover: the primary buttons only.
    case menubar
    /// Under a request in the list.
    case inline
    /// The inbox detail: every field.
    case detail
}

/// The answer controls of one request, by kind. A closed request shows its
/// closed state instead ("Answered on iPhone").
struct FeedAnswerControls: View {
    let item: FeedItem
    let model: FeedModel
    var density: FeedDensity = .inline
    @Environment(\.feedColors) private var colors

    var body: some View {
        if let closed = FeedStrings.closed(item) {
            Label(closed, systemImage: item.state == .answered ? "checkmark" : "minus.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(colors.tertiary)
        } else {
            controls
                .disabled(model.isPending(item.id) || model.connection != .connected)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch item.prompt {
        case .notice:
            EmptyView()
        case let .approve(prompt):
            FeedApproveControls(item: item, prompt: prompt, model: model, density: density)
        case let .choice(prompt):
            if density == .menubar && !prompt.isOneTap {
                buttons(primary: FeedStrings.open) { model.open(item.id) }
            } else {
                FeedChoiceControls(item: item, prompt: prompt, model: model, density: density)
            }
        case let .question(prompt):
            if density == .menubar {
                buttons(primary: FeedStrings.open) { model.open(item.id) }
            } else {
                FeedQuestionControls(item: item, prompt: prompt, model: model, density: density)
            }
        case let .confirm(prompt):
            buttons(primary: prompt.confirmLabel ?? FeedStrings.confirm, decline: prompt.cancelLabel,
                    destructive: prompt.destructive) { model.answer(item.id, .confirm(true)) }
        case .signIn:
            buttons(primary: FeedStrings.signIn) { model.open(item.id) }
        case .passkey:
            buttons(primary: FeedStrings.usePasskey) { model.open(item.id) }
        case .review:
            FeedReviewControls(item: item, model: model, density: density)
        case .handoff:
            buttons(primary: FeedStrings.takeOver) {
                model.answer(item.id, .handoff(.takenOver, note: nil))
                model.open(item.id)
            }
        case .file:
            buttons(primary: FeedStrings.chooseFile) { model.open(item.id) }
        case .input, .custom:
            buttons(primary: FeedStrings.open) { model.open(item.id) }
        }
    }

    /// Decline (secondary) and the primary action. A `confirm` declines with
    /// `confirmed: false`; everything else with `feed.cancel`.
    private func buttons(primary: String, decline: String? = nil, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(decline ?? FeedStrings.decline) {
                if case .confirm = item.prompt { model.answer(item.id, .confirm(false)) } else { model.decline(item.id) }
            }
            .buttonStyle(FeedButtonStyle(role: .plain, compact: density == .menubar))
            Button(primary, action: action)
                .buttonStyle(FeedButtonStyle(role: destructive ? .destructive : .primary, compact: density == .menubar))
        }
    }
}

extension FeedPrompt.Choice {
    /// One single-select question: a tap on an option answers.
    var isOneTap: Bool { questions.count == 1 && questions.allSatisfy { !$0.multi && !$0.allowOther } }
}
