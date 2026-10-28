import CmuxAgentQuestion
import CmuxMobileDiff
import CmuxMobileMarkdown
import Foundation
import Observation

/// One prompt and everything the agent did for it.
public struct AgentTurn: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable { case running, completed, cancelled, failed }

    public var id: String
    public var prompt: String
    public var attachments: [AgentAttachment]
    public var promptAt: Date
    public var items: [TurnItem] = []
    public var status: Status = .running
    public var startedAt: Date?
    public var endedAt: Date?
    public var errorText: String?
    /// The model request is being retried (attempt, of at most), while the turn runs.
    public var retry: Retry?
    /// Tool calls drawn by something else (the subagent row that a spawn call started).
    public var hiddenToolCalls: Set<String> = []

    public init(id: String, prompt: String, attachments: [AgentAttachment] = [], promptAt: Date) {
        self.id = id
        self.prompt = prompt
        self.attachments = attachments
        self.promptAt = promptAt
    }

    public struct Retry: Hashable, Sendable {
        public var attempt: Int
        public var maxAttempts: Int
        public var status: Int?

        /// "Retrying (2 of 10)", with the HTTP status when the agent gave one.
        public var label: String {
            let count = maxAttempts > 0 ? "\(attempt) of \(maxAttempts)" : "\(attempt)"
            return status.map { "Retrying (\(count), error \($0))" } ?? "Retrying (\(count))"
        }
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// The edits in this turn, per path in order (the edited-files card and Changes).
    public var changeSet: DiffChangeSet? {
        let files = Self.diffFiles(edits)
        guard !files.isEmpty else { return nil }
        return DiffChangeSet(id: "turn-\(id)", title: "Changes", subtitle: "This turn", files: files)
    }

    /// The file edits of this turn's tool calls, in order. An edit still waiting on its
    /// permission, or refused, is not a change (the Mac skips it too).
    public var edits: [(path: String, oldText: String?, newText: String)] {
        var out: [(path: String, oldText: String?, newText: String)] = []
        for case .tool(let call) in items where call.status != .pending && call.status != .failed {
            out += call.diffs
        }
        return out
    }

    /// One file per path, first-edit order, each built from all its edits in order.
    public static func diffFiles(_ edits: [(path: String, oldText: String?, newText: String)]) -> [DiffFile] {
        var order: [String] = []
        var byPath: [String: [(oldText: String?, newText: String)]] = [:]
        for edit in edits {
            if byPath[edit.path] == nil { order.append(edit.path) }
            byPath[edit.path, default: []].append((edit.oldText, edit.newText))
        }
        return order.map { DiffFile(path: $0, edits: byPath[$0] ?? []) }
    }

    public func question(_ id: String) -> AgentQuestion? {
        for case .question(let question) in items where question.id == id { return question }
        return nil
    }

    /// The turn's last agent message: what a list's preview shows (the chat's newest
    /// words, not the turn's first message, full verify D13).
    public var lastAnswerMarkdown: String? {
        for case .message(_, let text) in items.reversed() where !text.isEmpty { return text }
        return nil
    }

    /// The final answer text (copy, share).
    public var answerMarkdown: String {
        items.compactMap {
            if case .message(_, let text) = $0 { return text }
            return nil
        }.joined(separator: "\n\n")
    }
}

public enum TurnItem: Hashable, Sendable, Identifiable {
    case message(id: String, markdown: String)
    case thought(id: String, text: String)
    case tool(ACPToolCall)
    case plan(id: String, entries: [ACPPlanEntry])
    case permission(PermissionRecord)
    case question(AgentQuestion)
    /// Subagents started together (ids into `AgentChatStore.subagents`).
    case subagents(id: String, ids: [String])

    public var id: String {
        switch self {
        case .subagents(let id, _): "s-\(id)"
        case .message(let id, _): "m-\(id)"
        case .thought(let id, _): "t-\(id)"
        case .tool(let call): "c-\(call.id)"
        case .plan(let id, _): "p-\(id)"
        case .permission(let record): "r-\(record.request.id)"
        case .question(let question): "q-\(question.id)"
        }
    }
}

public struct PermissionRecord: Hashable, Sendable {
    public var request: ACPPermissionRequest
    /// The chosen option once resolved (nil option = cancelled).
    public var resolution: Resolution?

    public enum Resolution: Hashable, Sendable {
        case chose(ACPPermissionOption)
        case cancelled
    }

    public init(request: ACPPermissionRequest, resolution: Resolution? = nil) {
        self.request = request
        self.resolution = resolution
    }
}

public struct QueuedPrompt: Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
}

/// The chat's state, built from the source's event stream. Views read it; intents go back to the source.
@MainActor
@Observable
public final class AgentChatStore {
    public let source: any AgentSessionSource
    public private(set) var summary: AgentSessionSummary
    public private(set) var turns: [AgentTurn] = []
    public private(set) var queue: [QueuedPrompt] = []
    public private(set) var availableCommands: [ACPAvailableCommand] = []
    public private(set) var configOptions: [ACPConfigOption] = []
    public private(set) var models: [ACPModelInfo] = []
    public private(set) var currentModelID: String?
    public private(set) var modes: [ACPMode] = []
    /// Every mode the agent offers; ``modes`` is what a phone may pick (``ACPMode/phoneChoices(_:current:fullAccess:)``).
    private var offeredModes: [ACPMode] = []
    /// This phone's Full-access setting covers it (``AgentSessionEvent/fullAccess(_:)``).
    private var fullAccess = false
    public private(set) var currentModeID: String?
    public private(set) var usage: (used: Int, size: Int)?
    /// The chat opened on its newest history only: older records stay on the Mac, so the
    /// first turn shown is not where the session started (``AgentSessionEvent/earlierHistory(_:)``).
    public private(set) var hasEarlierHistory = false
    /// The title the agent gave the session (`session_info_update`).
    public private(set) var sessionTitle: String?

    /// The chat's title: the agent's session title, else the session's name, else (a new
    /// session) the first prompt trimmed to 40 characters, as ChatGPT and Claude do.
    public var displayTitle: String {
        Self.chatTitle(sessionTitle: sessionTitle, name: summary.name, firstPrompt: turns.first?.prompt)
    }

    public nonisolated static let untitledName = "New session"

    public nonisolated static func chatTitle(sessionTitle: String?, name: String, firstPrompt: String?) -> String {
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, trimmedName != untitledName { return trimmedName }
        let prompt = (firstPrompt ?? "").split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !prompt.isEmpty else { return trimmedName.isEmpty ? untitledName : trimmedName }
        guard prompt.count > 40 else { return prompt }
        let cut = prompt.prefix(40)
        // Cut at a word boundary when one is close, then add an ellipsis.
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return (word.count >= 24 ? String(word) : String(cut)).trimmingCharacters(in: .whitespaces) + "…"
    }
    /// Every subagent seen, nested ones included, in start order.
    public private(set) var subagents: [AgentSubagent] = []
    /// The newest refused intent, shown over the composer until the next send.
    public var clientError: String?
    /// The allow option waiting for Face ID (nil otherwise).
    public private(set) var approvingOptionID: String?
    /// A prompt that was not sent, for the composer to put back (then cleared).
    public var returnedDraft: ReturnedDraft?

    public struct ReturnedDraft: Hashable, Sendable {
        public var id = UUID()
        public var text: String
        public var attachments: [AgentAttachment]
        /// The prompt's acpmux id: sending the same text again reuses it, so the Mac runs it once.
        public var promptID: String?
    }
    /// A returned draft the Mac turned out to have run (its prompt id showed up in the
    /// transcript after the link came back): the composer takes it out again (then clears this).
    public var withdrawnDraft: ReturnedDraft?
    /// What this phone attached to each prompt it sent, by prompt id: the Mac's record of the
    /// prompt names its images only (and no files), so the sent bubble keeps what was sent.
    @ObservationIgnored private var sentAttachments: [String: [AgentAttachment]] = [:]
    @ObservationIgnored private var sentOrder: [String] = []
    /// The last returned prompt still waiting for a resend: what it held and its id.
    private var resendable: (text: String, attachments: [AgentAttachment], promptID: String)?
    /// Prompt ids the transcript showed running or queued (a lost reply for one of them is not
    /// a prompt that never went out).
    private var seenPromptIDs: Set<String> = []
    /// Bumps on every streamed change (follow-mode scroll keys off it).
    public private(set) var revision = 0
    /// Turn and row ids (`TurnRow.id`) that came in as replayed history (a `.batch`: the
    /// transcript on open, or what a reattach caught up on). They are drawn in place: no
    /// insert animation, no haptic. Only what arrives after the replay boundary animates.
    /// Not observed: it changes only with `turns`, which the views already observe.
    @ObservationIgnored private var replayedIDs: Set<String> = []
    /// What the chat's first batch (its history on open) held: an ask in it was already
    /// waiting and does not buzz; one a later batch (a reattach) brings is news.
    @ObservationIgnored private var openingIDs: Set<String>?
    /// Asks a decision or an answer resolved (not a turn that ended under them).
    @ObservationIgnored private var decidedAsks: Set<String> = []
    /// The newest change was a replayed batch: views that animate on a value change
    /// (the permission bar, the queue) draw it in place.
    @ObservationIgnored public private(set) var lastChangeWasReplay = false
    /// Set by the composer when it took its place without motion (the chat opened on its
    /// history): the bottom stack's next height lands at once too (then cleared).
    @ObservationIgnored var placeBottomStackInstantly = false
    private var currentMessageID: String?
    private var task: Task<Void, Never>?

    public init(source: any AgentSessionSource) {
        self.source = source
        self.summary = source.summary
        let stream = source.events()
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }

    public var isRunning: Bool { turns.last?.status == .running }

    public var pendingPermission: PermissionRecord? {
        guard let turn = turns.last else { return nil }
        for case .permission(let record) in turn.items.reversed() where record.resolution == nil {
            return record
        }
        return nil
    }

    public var pendingQuestion: AgentQuestion? {
        guard let turn = turns.last else { return nil }
        for case .question(let question) in turn.items.reversed() where question.isPending {
            return question
        }
        return nil
    }

    public var currentModelName: String? {
        models.first { $0.id == currentModelID }?.name
    }

    public var effortOption: ACPConfigOption? { configOptions.first(where: \.isEffort) }

    // MARK: Intents

    /// `denyingPermission`: the message is "Reply instead" for the pending
    /// permission (SPEC 6.5): deny it so the agent goes on, and send the
    /// message as guidance. A plain message while a permission waits queues.
    public func send(prompt: String, attachments: [AgentAttachment] = [], steer: Bool = false, denyingPermission: Bool = false) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        clientError = nil
        if denyingPermission, let permission = pendingPermission {
            let options = permission.request.phoneOptions
            let deny = options.first { $0.kind == .rejectOnce } ?? options.first { !$0.isAllow }
            respond(to: permission.request, option: deny)
        }
        // The same prompt sent again after its reply was lost keeps its id: acpmux runs it once.
        let resend = resendable.flatMap { pending in
            pending.text == text && pending.attachments.map(\.id) == attachments.map(\.id) ? pending.promptID : nil
        }
        resendable = nil
        let promptID = resend ?? UUID().uuidString.lowercased()
        keepSent(attachments, promptID: promptID)
        source.send(.prompt(text: text, attachments: attachments, steer: steer,
                            promptID: promptID, resend: resend != nil))
    }

    /// The Mac shows `promptID` ran (or queued): a draft returned for it goes away, and it is
    /// never sent again under that id.
    private func reached(_ promptID: String) {
        seenPromptIDs.insert(promptID)
        guard let pending = resendable, pending.promptID == promptID else { return }
        resendable = nil
        let draft = returnedDraft?.promptID == promptID ? returnedDraft : nil
        if draft != nil { returnedDraft = nil }
        withdrawnDraft = draft ?? ReturnedDraft(text: pending.text, attachments: pending.attachments, promptID: promptID)
        if clientError != nil { clientError = nil }
    }

    public func cancel() { source.send(.cancel) }

    public func respond(to request: ACPPermissionRequest, option: ACPPermissionOption?) {
        // A refusal is about the previous answer ("Approve this on your Mac"):
        // a new answer, such as the decline that follows, replaces it.
        clientError = nil
        // An allow is signed after Face ID: the bar shows "Waiting for Face ID…" until the
        // decision lands or the signature fails (cancelled Face ID comes back as an error).
        approvingOptionID = option?.isAllow == true ? option?.id : nil
        source.send(.respondPermission(permissionId: request.id, optionId: option?.id))
    }

    /// Declines a pending question with its reject option.
    public func decline(_ question: AgentQuestion) {
        guard question.isPending, let reject = question.source.rejectOption else { return }
        clientError = nil
        source.send(.respondPermission(permissionId: question.id, optionId: reject))
    }

    public func answer(_ question: AgentQuestion, with answer: AgentQuestionAnswer) {
        clientError = nil
        source.send(.answerQuestion(questionId: question.id, answer: answer))
    }

    public func setModel(_ id: String) { source.send(.setModel(id)) }
    public func setMode(_ id: String) { source.send(.setMode(id)) }
    public func setConfig(_ id: String, value: String) { source.send(.setConfigOption(id: id, value: value)) }
    public func removeQueued(_ id: String) { source.send(.removeQueued(promptId: id)) }
    /// Edit queued prompt (the agent pane's wording): the new text keeps its place.
    public func editQueued(_ id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, queue.contains(where: { $0.id == id && $0.text != text }) else { return }
        source.send(.editQueued(promptId: id, text: text))
    }
    /// Send now: the waiting prompt goes now (steered into the running turn, or next).
    public func sendQueuedNow(_ id: String) { source.send(.sendQueuedNow(promptId: id)) }
    /// Move up (-1) / Move down (+1) in the queue.
    public func moveQueued(_ id: String, by offset: Int) {
        guard let from = queue.firstIndex(where: { $0.id == id }), queue.indices.contains(from + offset) else { return }
        source.send(.moveQueued(promptId: id, index: from + offset))
    }

    /// The most prompts whose attachments wait for the Mac's record (each holds its bytes).
    static let maxSentAttachmentPrompts = 8

    /// Keeps what a prompt sent until its record arrives; a returned draft sent again under a new
    /// id drops the old id's entry, and the oldest go past the cap.
    private func keepSent(_ attachments: [AgentAttachment], promptID: String) {
        let ids = Set(attachments.map(\.id))
        if !ids.isEmpty {
            for (id, kept) in sentAttachments where id != promptID && Set(kept.map(\.id)) == ids { sentAttachments[id] = nil }
        }
        sentOrder.removeAll { $0 == promptID || sentAttachments[$0] == nil }
        guard !attachments.isEmpty else { return }
        sentAttachments[promptID] = attachments
        sentOrder.append(promptID)
        while sentOrder.count > Self.maxSentAttachmentPrompts { sentAttachments[sentOrder.removeFirst()] = nil }
    }

    /// Kept prompts in the order they were sent (the cap drops the oldest).
    var sentAttachmentPromptCount: Int { sentAttachments.count }

    // MARK: Reducer

    /// A turn's attachments: what this phone sent (with their bytes), else what the Mac's record
    /// names (its images, whose bytes `AgentSessionSource.attachmentData` reads on demand).
    static func sentAttachments(_ sent: [AgentAttachment]?, recorded: [AgentAttachment]) -> [AgentAttachment] {
        guard let sent, !sent.isEmpty else { return recorded }
        return sent
    }

    func apply(_ event: AgentSessionEvent) {
        revision &+= 1
        lastChangeWasReplay = false
        placeBottomStackInstantly = false
        switch event {
        case .userMessage(let text, let promptId, let turnId, let attachments, let at):
            currentMessageID = nil
            reached(promptId)
            if !turns.contains(where: { $0.id == turnId }) {
                turns.append(AgentTurn(id: turnId, prompt: text, attachments: Self.sentAttachments(sentAttachments[promptId], recorded: attachments),
                                       promptAt: at))
            }
            // The turn holds them now.
            sentAttachments[promptId] = nil
        case .queued(let text, let promptId, _):
            reached(promptId)
            queue.append(QueuedPrompt(id: promptId, text: text))
        case .dequeued(let promptId):
            queue.removeAll { $0.id == promptId }
        case .queueUpdated(let promptId, let text):
            if let index = queue.firstIndex(where: { $0.id == promptId }) { queue[index].text = text }
        case .queueOrder(let order):
            let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            queue.sort { (place[$0.id] ?? .max) < (place[$1.id] ?? .max) }
        case .turnStarted(let turnId, let at):
            mutateTurn(turnId) {
                $0.startedAt = at
                $0.status = .running
            }
            summary.status = .running
        case .retrying(let attempt, let maxAttempts, let status):
            guard let index = turns.indices.last, turns[index].status == .running else { return }
            turns[index].retry = AgentTurn.Retry(attempt: attempt, maxAttempts: maxAttempts, status: status)
        case .turnResult(let turnId, let status, let errorText, let at):
            mutateTurn(turnId) { turn in
                turn.retry = nil
                turn.status = status
                turn.endedAt = at
                turn.errorText = errorText
                for index in turn.items.indices {
                    switch turn.items[index] {
                    case .tool(var call) where call.isRunning:
                        call.status = status == .completed ? .completed : .failed
                        turn.items[index] = .tool(call)
                    // Requests the turn no longer waits on stop looking live.
                    case .question(var question) where question.isPending:
                        question.state = .cancelled
                        turn.items[index] = .question(question)
                    case .permission(var record) where record.resolution == nil:
                        record.resolution = .cancelled
                        turn.items[index] = .permission(record)
                    default:
                        break
                    }
                }
            }
            currentMessageID = nil
            summary.status = .idle
        case .update(let update):
            // The model answered: the retry is over.
            switch update {
            case .agentMessageChunk, .agentThoughtChunk, .toolCall:
                if let index = turns.indices.last, turns[index].retry != nil { turns[index].retry = nil }
            default:
                break
            }
            applyUpdate(update)
        case .permissionRequest(let request):
            guard takeOpenAsk(request.id) else { return }
            appendItem(.permission(PermissionRecord(request: request)))
            summary.status = .waiting
        case .question(let question):
            guard takeOpenAsk(question.id) else { return }
            appendItem(.question(question))
            summary.status = .waiting
        case .permissionDecision(let permissionId, let optionId, let answers):
            approvingOptionID = nil
            decidedAsks.insert(permissionId)
            updateItems { item in
                // A question resolves through the same decision: its answer option, or a decline.
                if case .question(var question) = item, question.id == permissionId, question.isPending {
                    // An ACP question's choices are the permission options themselves: any one
                    // chosen is its answer, but its reject option (Decline) is a decline.
                    // Other harnesses answer through `answerOption`.
                    let answered = optionId != nil && (question.source.harness == .acp
                        ? optionId != question.source.rejectOption
                        : optionId == question.source.answerOption)
                    question.state = answered ? .answered(question.recordedAnswer(answers, optionId: optionId)) : .cancelled
                    return .question(question)
                }
                guard case .permission(var record) = item, record.request.id == permissionId else { return nil }
                if let optionId, let option = record.request.options.first(where: { $0.id == optionId }) {
                    record.resolution = .chose(option)
                } else {
                    record.resolution = .cancelled
                }
                return .permission(record)
            }
            summary.status = isRunning ? .running : .idle
        case .questionAnswered(let questionId, let answer):
            decidedAsks.insert(questionId)
            updateItems { item in
                guard case .question(var question) = item, question.id == questionId else { return nil }
                question.state = .answered(answer)
                return .question(question)
            }
            summary.status = isRunning ? .running : .idle
        case .modelsAvailable(let models, let current):
            self.models = models
            currentModelID = current
        case .modesAvailable(let modes, let current):
            offeredModes = modes
            self.modes = ACPMode.phoneChoices(modes, current: current, fullAccess: fullAccess)
            currentModeID = current
        case .earlierHistory(let earlier):
            hasEarlierHistory = earlier
        case .fullAccess(let on):
            fullAccess = on
            modes = ACPMode.phoneChoices(offeredModes, current: currentModeID, fullAccess: on)
        case .status(let status):
            summary.status = status
        case .clientError(let message):
            approvingOptionID = nil
            clientError = message
        case .promptNotSent(let text, let attachments, let promptID, let reason):
            // The transcript already showed it run: only its reply was lost.
            guard !seenPromptIDs.contains(promptID) else { break }
            clientError = reason
            returnedDraft = ReturnedDraft(text: text, attachments: attachments, promptID: promptID)
            resendable = (text, attachments, promptID)
        case .subagent(let change):
            applySubagent(change)
        case .batch(let events):
            for event in events { apply(event) }
            markReplayed()
            lastChangeWasReplay = true
        case .subagentUpdate(let id, let update):
            guard let index = subagents.firstIndex(where: { $0.id == id }) else { return }
            subagents[index].items.apply(update)
            if case .toolCall(let call) = update { subagents[index].action = call.title }
            if case .toolCallUpdate(let call) = update, let title = call.title { subagents[index].action = title }
        }
    }

    public func subagent(_ id: String) -> AgentSubagent? { subagents.first { $0.id == id } }

    /// Whether `id` (a turn's id or a `TurnRow.id`) was on screen as replayed history,
    /// so its view appears without an insert transition (and its ask without a haptic).
    public func isReplayed(_ id: String) -> Bool { replayedIDs.contains(id) }

    /// Whether `id` (a `TurnRow.id`) was already there when the chat opened (its first batch).
    public func wasOpenOnArrival(_ id: String) -> Bool { openingIDs?.contains(id) ?? false }

    /// Everything shown now is history: what a batch brought, and anything before it.
    private func markReplayed() {
        for turn in turns {
            replayedIDs.insert(turn.id)
            for row in turn.rows { replayedIDs.insert(row.id) }
        }
        // The opening set is the first batch that brought the transcript.
        if openingIDs == nil, !turns.isEmpty { openingIDs = replayedIDs }
    }

    private func applySubagent(_ change: AgentSubagentChange) {
        if let index = subagents.firstIndex(where: { $0.id == change.id }) {
            if let name = change.name { subagents[index].name = name }
            if let task = change.task { subagents[index].task = task }
            if let state = change.state, state != subagents[index].state {
                subagents[index].state = state
                subagents[index].endedAt = state == .running ? nil : change.at
            }
            return
        }
        var agent = AgentSubagent(id: change.id, parent: change.parent, name: change.name ?? change.task ?? change.id,
                                  task: change.task, state: change.state ?? .running, startedAt: change.at, turnID: turns.last?.id)
        if agent.state != .running { agent.endedAt = change.at }
        subagents.append(agent)
        if let parent = change.parent, let index = subagents.firstIndex(where: { $0.id == parent }) {
            if case .subagents(let group, let ids)? = subagents[index].items.last {
                subagents[index].items[subagents[index].items.count - 1] = .subagents(id: group, ids: ids + [change.id])
            } else {
                subagents[index].items.append(.subagents(id: change.id, ids: [change.id]))
            }
            return
        }
        guard !turns.isEmpty else { return }
        let last = turns.count - 1
        if let call = change.toolCallID { turns[last].hiddenToolCalls.insert(call) }
        // Subagents spawned with no prose between them share one group; their
        // spawn tool calls are drawn by the group, so they don't split it.
        let hidden = turns[last].hiddenToolCalls
        let anchor = turns[last].items.lastIndex { item in
            if case .tool(let call) = item, hidden.contains(call.id) { return false }
            return true
        }
        if let anchor, case .subagents(let group, let ids) = turns[last].items[anchor] {
            turns[last].items[anchor] = .subagents(id: group, ids: ids + [change.id])
        } else {
            turns[last].items.append(.subagents(id: change.id, ids: [change.id]))
        }
    }

    private func applyUpdate(_ update: ACPSessionUpdate) {
        switch update {
        case .agentMessageChunk(let text, let messageId):
            guard var turn = turns.last else { return }
            if case .message(let id, let existing)? = turn.items.last, messageId == nil || messageId == currentMessageID || currentMessageID == nil {
                turn.items[turn.items.count - 1] = .message(id: id, markdown: existing + text)
            } else {
                turn.items.append(.message(id: messageId ?? UUID().uuidString, markdown: text))
            }
            currentMessageID = messageId
            turns[turns.count - 1] = turn
        case .agentThoughtChunk(let text):
            guard var turn = turns.last else { return }
            if case .thought(let id, let existing)? = turn.items.last {
                turn.items[turn.items.count - 1] = .thought(id: id, text: existing + text)
            } else {
                turn.items.append(.thought(id: UUID().uuidString, text: text))
            }
            turns[turns.count - 1] = turn
        case .toolCall(var call):
            call.startedAt = call.startedAt ?? Date()
            if call.status == .completed || call.status == .failed { call.endedAt = Date() }
            if !replaceTool(call.id, with: { _ in call }) {
                appendItem(.tool(call))
            }
        case .toolCallUpdate(let update):
            _ = replaceTool(update.toolCallId) { existing in
                var call = existing
                call.apply(update)
                if !call.isRunning, call.endedAt == nil { call.endedAt = Date() }
                return call
            }
        case .plan(let entries):
            guard var turn = turns.last else { return }
            if let index = turn.items.firstIndex(where: { if case .plan = $0 { return true }; return false }) {
                if entries.isEmpty {
                    turn.items.remove(at: index)
                } else if case .plan(let id, _) = turn.items[index] {
                    turn.items[index] = .plan(id: id, entries: entries)
                }
            } else if !entries.isEmpty {
                turn.items.append(.plan(id: UUID().uuidString, entries: entries))
            }
            turns[turns.count - 1] = turn
        case .availableCommands(let commands):
            availableCommands = commands
        case .currentMode(let mode):
            currentModeID = mode
            modes = ACPMode.phoneChoices(offeredModes, current: mode, fullAccess: fullAccess)
        case .configOptions(let options):
            configOptions = options
        case .usage(let used, let size):
            usage = (used, size)
        case .sessionInfo(let title):
            if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { sessionTitle = title }
        }
    }

    /// An ask seen again (shown from an attach reply's pending list, then its own record
    /// came with its turn): not decided, it leaves its old place for the newest turn (a
    /// turn that ended under it only cancelled it here); decided, the repeat is dropped.
    /// False: drop the repeat.
    private func takeOpenAsk(_ id: String) -> Bool {
        guard !decidedAsks.contains(id) else { return false }
        for turnIndex in turns.indices {
            guard let itemIndex = turns[turnIndex].items.firstIndex(where: { item in
                switch item {
                case .permission(let record): record.request.id == id
                case .question(let question): question.id == id
                default: false
                }
            }) else { continue }
            turns[turnIndex].items.remove(at: itemIndex)
            return true
        }
        return true
    }

    private func appendItem(_ item: TurnItem) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].items.append(item)
    }

    private func mutateTurn(_ id: String, _ body: (inout AgentTurn) -> Void) {
        guard let index = turns.lastIndex(where: { $0.id == id }) else { return }
        body(&turns[index])
    }

    @discardableResult
    private func replaceTool(_ id: String, with transform: (ACPToolCall) -> ACPToolCall) -> Bool {
        for turnIndex in turns.indices.reversed() {
            for itemIndex in turns[turnIndex].items.indices.reversed() {
                if case .tool(let call) = turns[turnIndex].items[itemIndex], call.id == id {
                    turns[turnIndex].items[itemIndex] = .tool(transform(call))
                    return true
                }
            }
        }
        return false
    }

    private func updateItems(_ transform: (TurnItem) -> TurnItem?) {
        for turnIndex in turns.indices.reversed() {
            for itemIndex in turns[turnIndex].items.indices {
                if let replaced = transform(turns[turnIndex].items[itemIndex]) {
                    turns[turnIndex].items[itemIndex] = replaced
                    return
                }
            }
        }
    }
}
