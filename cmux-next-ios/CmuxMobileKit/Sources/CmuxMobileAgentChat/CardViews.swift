#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileDesign
import CmuxMobileMarkdown
import SwiftUI

/// SPEC 6.7 plan card with live step glyphs.
struct PlanCard: View {
    let entries: [ACPPlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                Text("Plan").font(.headline)
                Spacer()
                Text("\(entries.count { $0.status == .completed }) of \(entries.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        glyph(entry.status)
                        Text(InlineMarkdownCache.shared.attributed(entry.content))
                            .font(.subheadline)
                            .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                            .strikethrough(entry.status == .completed, color: .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.cmuxMobileCard, in: .rect(cornerRadius: 20, style: .continuous))
        .animation(.cmuxMobileSmooth, value: entries)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func glyph(_ status: ACPPlanEntry.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .inProgress:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.primary)
                .symbolEffect(.rotate, options: .repeat(.continuous))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.cmuxMobileSuccess)
                .transition(.symbolEffect(.appear))
        }
    }
}

/// SPEC 6.5 permission card in the transcript; resolved requests collapse to a summary row.
struct PermissionCard: View {
    let record: PermissionRecord
    let agentName: String
    /// Set while the choices are out of the composer's place (the person is
    /// typing): brings them back.
    var showChoices: (() -> Void)?

    var body: some View {
        if let resolution = record.resolution {
            HStack(spacing: 8) {
                let allowed: Bool = if case .chose(let option) = resolution { option.isAllow } else { false }
                Image(systemName: allowed ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(summary(resolution)).font(.subheadline)
                Text(record.request.toolCall.command ?? record.request.toolCall.title)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 32)
            .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Color.cmuxMobileWarning)
                    Text("\(agentName) wants to \(action)").font(.headline)
                }
                if let command = record.request.toolCall.command {
                    CodeCard(language: "bash", code: command, title: "Command", maxHeight: 6 * 19 + 60)
                } else {
                    Text(record.request.toolCall.title).font(.subheadline.monospaced())
                }
                if let cwd = record.request.cwd {
                    Label(cwd, systemImage: "folder").font(.footnote).foregroundStyle(.secondary)
                }
                if let showChoices {
                    Button("Allow or deny…", action: showChoices)
                        .buttonStyle(CmuxMobileCapsuleButtonStyle(.secondary))
                        .transition(.opacity)
                }
            }
            .padding(16)
            .background(Color.cmuxMobileCard, in: .rect(cornerRadius: 20, style: .continuous))
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
        }
    }

    private var action: String {
        switch record.request.toolCall.kind {
        case .execute: "run a command"
        case .edit, .fileChange: "edit files"
        case .fetch: "fetch a URL"
        case .delete: "delete files"
        default: "use a tool"
        }
    }

    private func summary(_ resolution: PermissionRecord.Resolution) -> String {
        switch resolution {
        case .chose(let option):
            switch option.kind {
            case .allowOnce: "Allowed once"
            case .allowAlways: "Always allowed"
            case .rejectOnce, .rejectAlways: "Denied"
            }
        case .cancelled: "Cancelled"
        }
    }
}

/// The action bar that replaces the composer while a permission waits (SPEC 6.5).
public struct PermissionActionBar: View {
    let request: ACPPermissionRequest
    let respond: (ACPPermissionOption?) -> Void
    let replyInstead: (() -> Void)?
    /// The allow waiting for Face ID: its button spins, the other allows are disabled,
    /// Deny stays available.
    var approvingOptionID: String?

    public init(request: ACPPermissionRequest, approvingOptionID: String? = nil,
                respond: @escaping (ACPPermissionOption?) -> Void, replyInstead: (() -> Void)? = nil) {
        self.request = request
        self.approvingOptionID = approvingOptionID
        self.respond = respond
        self.replyInstead = replyInstead
    }

    /// Shown on the allow while Face ID runs (the Feed's string).
    public static let waitingForFaceID = "Waiting for Face ID…"
    /// Taps on a choice, for the tap's haptic.
    @State private var taps = 0

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(request.phoneOptions) { option in
                Button {
                    // The allow already waiting for Face ID ignores a second tap.
                    guard !(option.isAllow && approvingOptionID != nil) else { return }
                    taps += 1
                    respond(option)
                } label: {
                    // Long options ("Always allow cargo test in this workspace")
                    // wrap instead of truncating. An allow is signed after Face ID
                    // (verify/phone-approvals.md), and says so.
                    HStack(spacing: 6) {
                        if option.id == approvingOptionID {
                            ProgressView().controlSize(.small).tint(option.kind == .allowOnce ? Color.cmuxMobileOnAccent : Color.primary).accessibilityHidden(true)
                            Text(Self.waitingForFaceID).lineLimit(2).multilineTextAlignment(.center)
                        } else {
                            if option.isAllow { Image(systemName: "faceid").accessibilityHidden(true) }
                            Text(option.phoneLabel).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.9)
                        }
                    }
                    .animation(.cmuxMobileSnap, value: approvingOptionID)
                }
                    .disabled(approvingOptionID != nil && option.isAllow && option.id != approvingOptionID)
                    .accessibilityHint(option.isAllow ? "Approve with Face ID" : "")
                    .buttonStyle(CmuxMobileCapsuleButtonStyle(style(option), size: .bar))
            }
            if let replyInstead {
                Button("Reply instead", action: replyInstead)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 120, minHeight: 44)
                    .contentShape(.rect)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    private func style(_ option: ACPPermissionOption) -> CmuxMobileCapsuleButtonStyle.Kind {
        switch option.kind {
        case .allowOnce: .primary
        case .allowAlways: .secondary
        case .rejectOnce, .rejectAlways: .destructive
        }
    }
}

/// SPEC 6.6 question card (AskUserQuestion / elicitation). Drives the shared
/// `AgentQuestionCardState` reducer; items page horizontally with "1 of N".
public struct QuestionCard: View {
    let question: AgentQuestion
    let submit: (AgentQuestionAnswer) -> Void
    var showsHeader: Bool
    @State private var state: AgentQuestionCardState
    @State private var forward = true
    @FocusState private var otherFocused: Bool
    @State private var submitted = 0
    #if DEBUG
    private let director = DemoDirector.shared
    #endif

    public init(question: AgentQuestion, showsHeader: Bool = true, submit: @escaping (AgentQuestionAnswer) -> Void) {
        self.question = question
        self.submit = submit
        self.showsHeader = showsHeader
        // A relaunch brings back a partly answered question where the person left it.
        let draft = QuestionDraftStore.shared.draft(for: question.id)
        _state = State(initialValue: draft?.restore(into: question) ?? AgentQuestionCardState(question: question))
    }

    public var body: some View {
        Group {
            if case .answered(let answer) = question.state {
                AnsweredSummary(question: question, answer: answer)
                    .transition(.opacity)
            } else if question.state == .cancelled {
                Label("Question cancelled", systemImage: "xmark.circle").font(.subheadline).foregroundStyle(.secondary)
            } else {
                card.transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
            }
        }
        .animation(.cmuxMobileSmooth, value: question.state)
        .onChange(of: question) { _, new in
            state.update(new)
            if !new.isPending { QuestionDraftStore.shared.clear(new.id) }
        }
        .onChange(of: state) { _, new in
            if question.isPending { QuestionDraftStore.shared.save(QuestionDraft(new), for: question.id) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: submitted)
        #if DEBUG
        .onChange(of: director.serial) { runDemoCommand() }
        #endif
    }

    private var card: some View {
        let item = state.item
        let count = question.items.count
        return VStack(alignment: .leading, spacing: 12) {
            if showsHeader || count > 1 {
                HStack(spacing: 8) {
                    if showsHeader {
                        Image(systemName: "questionmark.bubble")
                    }
                    if let header = item.header {
                        Text(header.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                    }
                    Spacer()
                    if count > 1 {
                        Text("\(state.activeItem + 1) of \(count)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(item.prompt).font(.headline).fixedSize(horizontal: false, vertical: true)
                if item.multiSelect {
                    Text("Choose any").font(.footnote).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    ForEach(Array(item.options.enumerated()), id: \.element.id) { index, option in
                        optionRow(option, item: item, row: index)
                    }
                    if item.allowsOther {
                        otherRow(item)
                    }
                }
            }
            .id(item.id)
            .transition(.asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
            ))
            HStack {
                if state.activeItem > 0 {
                    Button("Back") { page(-1) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                Spacer()
                // One rule: a single-choice step advances when an option is tapped, so it has
                // no Next. Multi-select steps (and Other text) need Next to finish the step.
                if state.activeItem < count - 1, needsNext(item) {
                    Button("Next") { page(1) }
                        .buttonStyle(CmuxMobileCapsuleButtonStyle(.secondary))
                        .disabled(state.answer.selections[item.id]?.isEmpty != false)
                }
                // Answer only on the last page (SPEC 6.6), or once every item is answered.
                if state.activeItem == count - 1 || state.canSubmit {
                    Button("Answer") { send(.submit) }
                        .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary))
                        .disabled(!state.canSubmit)
                }
            }
        }
        .padding(16)
        .background(Color.cmuxMobileCard, in: .rect(cornerRadius: 20, style: .continuous))
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
    }

    private func needsNext(_ item: AgentQuestion.Item) -> Bool {
        item.multiSelect || state.editingOther || !(state.otherDrafts[item.id] ?? "").isEmpty
    }

    private func optionRow(_ option: AgentQuestion.Option, item: AgentQuestion.Item, row: Int) -> some View {
        let chosen = state.isChosen(option, in: item)
        return Button {
            send(.click(row: row))
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.body)
                    if let detail = option.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                // Any-of: rounded-square checkboxes. One-of: circles.
                Image(systemName: item.multiSelect
                      ? (chosen ? "checkmark.square.fill" : "square")
                      : (chosen ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 20))
                    .foregroundStyle(chosen ? Color.primary : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(chosen ? Color.cmuxMobileFillSelected : Color.cmuxMobileFill, in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: chosen)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func otherRow(_ item: AgentQuestion.Item) -> some View {
        let editing = state.editingOther || !(state.otherDrafts[item.id] ?? "").isEmpty
        return Group {
            if editing {
                TextField("Other…", text: Binding(
                    get: { state.otherDrafts[item.id] ?? "" },
                    set: { send(.otherText($0)) }
                ), axis: .vertical)
                .focused($otherFocused)
                .submitLabel(.done)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .background(Color.cmuxMobileFillSelected, in: .rect(cornerRadius: 14, style: .continuous))
                .onAppear { otherFocused = true }
            } else {
                Button {
                    send(.click(row: item.options.count))
                } label: {
                    HStack {
                        Text("Other…").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "square.and.pencil").foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 14, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func page(_ delta: Int) {
        forward = delta > 0
        withAnimation(.cmuxMobileSmooth) { _ = state.send(delta > 0 ? .nextItem : .previousItem) }
    }

    private func send(_ input: AgentQuestionCardState.Input) {
        let before = state.activeItem
        var effect = AgentQuestionCardState.Effect.none
        forward = true
        withAnimation(.cmuxMobileSmooth) {
            effect = state.send(input)
        }
        if state.activeItem != before { forward = state.activeItem > before }
        switch effect {
        case .submit(let answer):
            submitted += 1
            QuestionDraftStore.shared.clear(question.id)
            otherFocused = false
            submit(answer)
        case .beginOtherEditing:
            otherFocused = true
        case .resign:
            otherFocused = false
        case .none:
            break
        }
    }

    #if DEBUG
    private func runDemoCommand() {
        guard let (id, picks) = director.take({ command -> (String, [[String]])? in
            if case .answerQuestion(let id, let picks) = command { return (id, picks) }
            return nil
        }), id == question.id else { return }
        Task {
            for (itemIndex, ids) in picks.enumerated() where question.items.indices.contains(itemIndex) {
                let item = question.items[itemIndex]
                if state.activeItem != itemIndex { page(itemIndex - state.activeItem) }
                try? await Task.sleep(for: .milliseconds(700))
                for id in ids {
                    if let row = item.options.firstIndex(where: { $0.id == id }) {
                        send(.click(row: row))
                        try? await Task.sleep(for: .milliseconds(600))
                    }
                }
                if item.multiSelect {
                    if itemIndex == question.items.count - 1 {
                        send(.submit)
                    } else {
                        page(1)
                    }
                }
            }
        }
    }
    #endif
}

/// "You answered" + the answer in a right-aligned bubble.
struct AnsweredSummary: View {
    let question: AgentQuestion
    let answer: AgentQuestionAnswer

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("You answered").font(.footnote).foregroundStyle(.secondary)
            ForEach(question.items) { item in
                let selection = answer.selections[item.id]
                let labels = item.options.filter { selection?.optionIDs.contains($0.id) == true }.map(\.label)
                    + [selection?.other].compactMap { $0 }.filter { !$0.isEmpty }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.header ?? item.prompt).font(.caption).foregroundStyle(.secondary)
                    Text(labels.joined(separator: ", "))
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.cmuxMobileBubble, in: .rect(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

/// SPEC 7.3 inline failure card.
struct FailureCard: View {
    let title: String
    let message: String
    /// The agent's own message, when the sentence says it in plain words (the Mac's Details).
    var detail: String?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 17))
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            if let detail {
                DisclosureGroup("Details") {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
                .tint(.secondary)
            }
            Button("Retry", action: retry).buttonStyle(CmuxMobileCapsuleButtonStyle(.primary, size: .large))
        }
        .padding(16)
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(uiColor: .separator), lineWidth: 1) }
    }
}
#endif
