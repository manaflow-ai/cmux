import SwiftUI

/// `choice`: option chips per question, an "Other" field where allowed, and
/// Send once every question has a valid answer. A single single-select
/// question answers on the tap.
struct FeedChoiceControls: View {
    let item: FeedItem
    let prompt: FeedPrompt.Choice
    let model: FeedModel
    var density: FeedDensity
    @Environment(\.feedColors) private var colors

    var body: some View {
        let answers = model.drafts.choices[item.id] ?? [:]
        let issues = FeedChoiceValidation.issues(answers, for: prompt)
        VStack(alignment: .leading, spacing: density == .menubar ? 4 : 10) {
            ForEach(prompt.questions) { question in
                VStack(alignment: .leading, spacing: 5) {
                    if density != .menubar {
                        Text(question.question)
                            .font(.system(size: 12))
                            .foregroundStyle(colors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    FeedFlowLayout(spacing: 5) {
                        ForEach(question.options) { option in
                            let selected = model.drafts.choice(item.id, question.id).selected.contains(option.id)
                            Button(option.label) { tap(question, option.id) }
                                .buttonStyle(FeedButtonStyle(role: .chip(selected: selected), compact: density == .menubar))
                                .help(option.detail ?? "")
                        }
                    }
                    if question.allowOther {
                        FeedTextField(placeholder: FeedStrings.other, text: otherBinding(question))
                            .frame(maxWidth: 260)
                    }
                }
            }
            if !prompt.isOneTap {
                HStack(spacing: 6) {
                    Button(FeedStrings.decline) { model.decline(item.id) }
                        .buttonStyle(FeedButtonStyle(role: .plain))
                    Button(FeedStrings.send) { model.submitChoice(item.id) }
                        .buttonStyle(FeedButtonStyle(role: .primary))
                        .disabled(!issues.isEmpty)
                        .help(issues.isEmpty ? "" : FeedStrings.pickOne)
                }
            }
        }
    }

    private func tap(_ question: FeedPrompt.ChoiceQuestion, _ option: String) {
        model.drafts.toggle(item.id, question: question, option: option)
        if prompt.isOneTap { model.submitChoice(item.id) }
    }

    private func otherBinding(_ question: FeedPrompt.ChoiceQuestion) -> Binding<String> {
        Binding(
            get: { model.drafts.choice(item.id, question.id).other ?? "" },
            set: { model.drafts.setOther(item.id, question: question, text: $0) })
    }
}

/// `question`: suggestion chips that fill the reply, the reply, Send.
struct FeedQuestionControls: View {
    let item: FeedItem
    let prompt: FeedPrompt.Question
    let model: FeedModel
    var density: FeedDensity

    private var reply: Binding<String> {
        Binding(get: { model.drafts.replies[item.id] ?? "" }, set: { model.drafts.replies[item.id] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !prompt.suggestions.isEmpty {
                FeedFlowLayout(spacing: 5) {
                    ForEach(prompt.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { reply.wrappedValue = suggestion }
                            .buttonStyle(FeedButtonStyle(role: .chip(selected: reply.wrappedValue == suggestion)))
                    }
                }
            }
            HStack(spacing: 6) {
                FeedTextField(placeholder: FeedStrings.reply, text: reply, onSubmit: send)
                Button(FeedStrings.send, action: send)
                    .buttonStyle(FeedButtonStyle(role: .primary))
                    .disabled(reply.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func send() {
        let text = reply.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.answer(item.id, .text(text))
    }
}

/// Lays children out left to right and wraps to the next line.
struct FeedFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if next > width && !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], next, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
