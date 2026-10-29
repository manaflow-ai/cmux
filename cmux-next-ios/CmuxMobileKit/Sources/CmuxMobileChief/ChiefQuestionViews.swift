#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileDesign
import SwiftUI
import UIKit

/// Under the chat header while Chief asks something: one glass bar, as
/// Messages shows a business chat's pending request, that opens the
/// question. It says where an answer is ("Waiting for Face ID…",
/// "Sending…") and goes away once the Mac stored it.
struct ChiefQuestionBar: View {
    let session: ChiefSession
    let open: (AgentQuestion) -> Void
    /// The bar grew, shrank or went away: its UIKit host lays it out again.
    var resized: () -> Void = {}
    /// The bar starts fading out (true) or in (false) over `duration`: the
    /// host fades its backing band with it (R3-2).
    var fading: (_ out: Bool, _ duration: Double) -> Void = { _, _ in }
    /// The away-Mac bar's Ask Cloud Chief (the screen hands over the composer's text).
    var askCloudChief: () -> Void = {}

    /// What the bar shows. It outlives `session.barItem` by the fade, so
    /// the bar leaves before the conversation moves up into its room (R3-2).
    @State private var shown: ChiefBarItem?
    @State private var visible = false

    static let fadeDuration = 0.2

    var body: some View {
        VStack(spacing: 0) { content }
            .onAppear {
                shown = session.barItem
                visible = shown != nil
                if visible { fading(false, 0) }
            }
            .onChange(of: session.barItem) { _, item in
                if let item {
                    let appearing = shown == nil
                    shown = item
                    guard appearing else { return }
                    // Room first, then the bar fades in.
                    resized()
                    fading(false, Self.fadeDuration)
                    withAnimation(.easeOut(duration: Self.fadeDuration)) { visible = true }
                } else if shown != nil {
                    // The bar fades out first; then the room closes.
                    fading(true, Self.fadeDuration)
                    withAnimation(.easeIn(duration: Self.fadeDuration)) {
                        visible = false
                    } completion: {
                        shown = nil
                        resized()
                    }
                }
            }
            .onChange(of: layoutKey) { resized() }
    }

    /// What changes the bar's height: the question, and its status line.
    private var layoutKey: String {
        switch shown {
        case .question(let question)?: question.id + (session.answers[question.id]?.statusText ?? "")
        case .failure(let id, _)?: id
        case .unavailable(let reason, let retrying)?: reason + (retrying ? "\u{0}" : "")
        case .macAway(let reason)?: "away\u{0}" + reason
        case nil: ""
        }
    }

    @ViewBuilder private var content: some View {
        if case .failure(_, let failure)? = shown {
            failureBar(failure)
        } else if case .unavailable(let reason, let retrying)? = shown {
            unavailableBar(reason: reason, retrying: retrying)
        } else if case .macAway(let reason)? = shown {
            macAwayBar(reason: reason)
        } else if case .question(let question)? = shown {
            let flow = session.answers[question.id] ?? ChiefAnswerFlow()
            Button { open(question) } label: {
                label(question, flow: flow)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    // Opaque: nothing scrolled under the header shows through (R2-1).
                    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
            }
            // A bar over the transcript: it may grow with the text, but not
            // past the point where it hides the conversation.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("chief.question.bar")
            .accessibilityHint("Opens Chief's question")
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Chief's newest turn failed: the reason in plain words and Try Again,
    /// which sends the message it was answering again.
    private func failureBar(_ failure: ChiefTurnFailure) -> some View {
        Button { session.retryFailedTurn() } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.bubble.fill").font(.body).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(failure.barTitle).font(.footnote.weight(.semibold))
                    Text("Send your last message again.").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("Try Again").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("chief.failure.bar")
        .accessibilityHint("Sends your last message to Chief again")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    /// The Mac's Chief can't be reached (refused, not running, no Mac): why,
    /// in its own words, and Try Again when the link can try. Replaces the
    /// conversation's first-load spinner, which never ends without Chief.
    private func unavailableBar(reason: String, retrying: Bool) -> some View {
        Button { session.retryConnecting() } label: {
            HStack(spacing: 10) {
                if retrying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").font(.body).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Chief isn't available").font(.footnote.weight(.semibold))
                    Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 4)
                if session.canRetryConnecting {
                    Text(retrying ? "Trying…" : "Try Again").font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .buttonStyle(.plain)
        .disabled(retrying || !session.canRetryConnecting)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("chief.unavailable.bar")
        .accessibilityHint(session.canRetryConnecting ? "Tries to reach Chief on your Mac again" : "")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    /// The Mac is away: Chief reads its cloud copy, so what is sent waits
    /// for the Mac. Ask Cloud Chief hands the composer's text (or the newest
    /// message) to the Cloud Chief now. It was a navigation bar button the
    /// hidden bar never showed.
    private func macAwayBar(reason: String) -> some View {
        Button { askCloudChief() } label: {
            HStack(spacing: 10) {
                Image(systemName: "icloud").font(.body).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reason).font(.footnote.weight(.semibold)).lineLimit(2)
                    Text("Messages wait for your Mac.").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("Ask Cloud Chief").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("chief.askCloudChief")
        .accessibilityHint("Sends your message to Cloud Chief with this chat's recent messages")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    @ViewBuilder private func label(_ question: AgentQuestion, flow: ChiefAnswerFlow) -> some View {
        let icon = Group {
            if flow.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "questionmark.bubble.fill").font(.body)
            }
        }
        let detail = Text(flow.statusText ?? question.items.first?.prompt ?? "")
            .font(.footnote)
            .foregroundStyle(isFailed(flow) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .lineLimit(2)
        if typeSize.isAccessibilitySize {
            // Stacked, as Home's rows are at these sizes.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    icon
                    Text("Chief is asking").font(.footnote.weight(.semibold)).lineLimit(1)
                }
                detail
                if offersAnswer(flow) { Text("Answer").font(.footnote.weight(.semibold)) }
            }
        } else {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text("Chief is asking").font(.footnote.weight(.semibold))
                    detail
                }
                Spacer(minLength: 4)
                if offersAnswer(flow) {
                    Text("Answer").font(.footnote.weight(.semibold))
                }
            }
        }
    }

    /// "Answer" only while there is something to do: not in flight, and not
    /// on a sent answer while the bar fades out.
    private func offersAnswer(_ flow: ChiefAnswerFlow) -> Bool {
        !flow.isBusy && flow.state != .sent
    }

    private func isFailed(_ flow: ChiefAnswerFlow) -> Bool {
        if case .failed = flow.state { return true }
        return false
    }
}

/// Chief's question, answered here. The question and its choices scroll;
/// the status line and the one action stay pinned at the bottom of the
/// sheet, so they are on screen at every text size (R2-2). Choosing an
/// option only selects it; "Send Answer" (Face ID) sends (R2-8). The sheet
/// closes only once the Mac stored the answer.
struct ChiefQuestionSheet: View {
    let session: ChiefSession
    let questionID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var chosen: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    static let sentHold: Duration = .milliseconds(600)

    private var question: AgentQuestion? { session.questions.first { $0.id == questionID } }
    private var flow: ChiefAnswerFlow { session.answers[questionID] ?? ChiefAnswerFlow() }

    /// What the person chose so far, as the Mac takes it.
    private var answer: AgentQuestionAnswer? {
        guard let question else { return nil }
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for item in question.items {
            let ids = item.options.map(\.id).filter { chosen[item.id]?.contains($0) == true }
            selections[item.id] = .init(optionIDs: ids, other: other[item.id])
        }
        return AgentQuestionAnswer(selections: selections)
    }

    private var canSend: Bool {
        guard let question, let answer, question.isPending, !flow.isBusy else { return false }
        if case .unconfirmed = flow.state { return false }
        return answer.problems(for: question).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // The title already says whose question it is.
                    if !typeSize.isAccessibilitySize { header }
                    if let question {
                        if case .answered(let given) = question.state {
                            answered(question, given)
                        } else if question.state == .cancelled {
                            Label("Chief withdrew this question", systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(question.items) { item in itemView(item) }
                        }
                    }
                }
                .padding(16)
                // At accessibility sizes every choice still fits near the
                // fold (R3-4); the indicator flashes to show the rest scrolls.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .navigationTitle("Chief's Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("chief.question.close")
                }
            }
        }
        // "Sent" with its check stays a beat before the sheet closes (R3-3):
        // an intentional, bounded hold, cancelled if the sheet goes first.
        .task(id: flow.state == .sent) {
            guard flow.state == .sent else { return }
            try? await Task.sleep(for: Self.sentHold)
            if !Task.isCancelled { dismiss() }
        }
        .accessibilityIdentifier("chief.question.sheet")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ChiefAvatar(text: session.avatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? session.identity.title).font(.headline)
                if !typeSize.isAccessibilitySize {
                    Text("Your answer is signed with Face ID on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func itemView(_ item: AgentQuestion.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = item.header {
                Text(header.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            }
            Text(item.prompt).font(.headline).fixedSize(horizontal: false, vertical: true)
            if item.multiSelect {
                Text("Choose any").font(.footnote).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(item.options) { option in optionRow(option, in: item) }
                if item.allowsOther {
                    TextField("Other…", text: Binding(
                        get: { other[item.id] ?? "" },
                        set: { text in
                            other[item.id] = text
                            if !item.multiSelect, !text.trimmingCharacters(in: .whitespaces).isEmpty { chosen[item.id] = [] }
                        }
                    ), axis: .vertical)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
                }
            }
            .disabled(flow.isBusy)
        }
    }

    private func optionRow(_ option: AgentQuestion.Option, in item: AgentQuestion.Item) -> some View {
        let isChosen = chosen[item.id]?.contains(option.id) == true
        return Button {
            if item.multiSelect {
                chosen[item.id, default: []].formSymmetricDifference([option.id])
            } else {
                chosen[item.id] = [option.id]
                other[item.id] = nil
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.body)
                    if let detail = option.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(Color(uiColor: isChosen ? .secondarySystemFill : .tertiarySystemFill),
                        in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isChosen)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func answered(_ question: AgentQuestion, _ given: AgentQuestionAnswer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You answered").font(.footnote).foregroundStyle(.secondary)
            ForEach(question.items) { item in
                let selection = given.selections[item.id]
                let labels = item.options.filter { selection?.optionIDs.contains($0.id) == true }.map(\.label)
                    + [selection?.other].compactMap { $0 }
                Text("\(item.header ?? item.prompt): \(labels.joined(separator: ", "))").font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The pinned bottom: the answer's state, then its one action.
    private var footer: some View {
        VStack(spacing: 10) {
            if let text = flow.statusText {
                statusRow(text)
            }
            if case .unconfirmed = flow.state {
                Button {
                    session.checkAnswer(questionID)
                } label: {
                    Text("Check").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("chief.question.check")
            } else if question?.isPending ?? false {
                Button {
                    if let question, let answer { session.answer(question, with: answer) }
                } label: {
                    Label("Send Answer", systemImage: "faceid").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSend)
                .accessibilityHint("Asks for Face ID, then sends your answer to Chief")
                .accessibilityIdentifier("chief.question.send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        // Pinned under a scrolling question: large, but never most of the sheet.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            if flow.isBusy {
                ProgressView().controlSize(.small)
            } else if flow.state == .sent {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if flow.state == .unconfirmed {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(flow.isBusy ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chief.question.status")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
#endif
