import CmuxAgentQuestion
import CmuxMobileDiff
import CmuxMobileMarkdown
import CmuxMobileModel
import Foundation
import Observation

/// One prompt and everything the agent did for it.
public struct AgentTurn: Identifiable, Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable { case running, completed, cancelled, failed }

    public var id: String
    public var prompt: String
    /// The id of the prompt that opened the turn: a later `userMessage` for the turn with another
    /// id is a message steered into it. Nil in a turn saved before it was kept.
    public var promptID: String?
    public var attachments: [AgentAttachment]
    public var promptAt: Date
    /// Another agent's message, when the prompt is one (AgentIncoming): drawn as its card.
    public var incoming: AgentIncoming?
    public var items: [TurnItem] = []
    public var status: Status = .running
    public var startedAt: Date?
    public var endedAt: Date?
    public var errorText: String?
    /// The model request is being retried (attempt, of at most), while the turn runs.
    public var retry: Retry?
    /// Tool calls drawn by something else (the subagent row that a spawn call started).
    public var hiddenToolCalls: Set<String> = []

    public init(id: String, prompt: String, promptID: String? = nil, attachments: [AgentAttachment] = [], promptAt: Date) {
        self.id = id
        self.prompt = prompt
        self.promptID = promptID
        self.attachments = attachments
        self.promptAt = promptAt
    }

    public struct Retry: Hashable, Sendable, Codable {
        public var attempt: Int
        public var maxAttempts: Int
        public var status: Int?

        /// "Retrying (2 of 10)", with the HTTP status when the agent gave one.
        public var label: String {
            let count = maxAttempts > 0 ? "\(attempt) of \(maxAttempts)" : "\(attempt)"
            return status.map { "Retrying (\(count), error \($0))" } ?? "Retrying (\(count))"
        }
    }

    /// A failed turn's error card leads with Continue when the turn had done work (a reply, a
    /// thought, a tool call) or had no prompt of its own (a turn a notice started), else Retry
    /// (the Mac's `errorRecovery.ts`). Both send acpmux's turn retry, which picks up where it stopped.
    public var continuesAfterFailure: Bool {
        status == .failed && (!items.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    /// A tool call of this turn wrote a file (`edits` is not empty), without building them.
    public var hasEdits: Bool {
        items.contains { item in
            guard case .tool(let call) = item, call.status != .pending, call.status != .failed else { return false }
            return call.content.contains { if case .diff = $0 { return true }; return false }
        }
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

public enum TurnItem: Hashable, Sendable, Codable, Identifiable {
    case message(id: String, markdown: String)
    case thought(id: String, text: String)
    case tool(ACPToolCall)
    case plan(id: String, entries: [ACPPlanEntry])
    case permission(PermissionRecord)
    case question(AgentQuestion)
    /// Subagents started together (ids into `AgentChatStore.subagents`).
    case subagents(id: String, ids: [String])
    /// A message steered into the running turn, where it went in (the Mac's steered row).
    case steer(SteeredMessage)

    public var id: String {
        switch self {
        case .steer(let message): "st-\(message.promptID)"
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

/// A message steered into a running turn: the person's, drawn as their bubble, or another
/// agent's (`incoming`), drawn as its card.
public struct SteeredMessage: Hashable, Sendable, Codable {
    public var promptID: String
    public var text: String
    public var attachments: [AgentAttachment]
    public var at: Date
    public var incoming: AgentIncoming?

    public init(promptID: String, text: String, attachments: [AgentAttachment] = [], at: Date, incoming: AgentIncoming? = nil) {
        self.promptID = promptID
        self.text = text
        self.attachments = attachments
        self.at = at
        self.incoming = incoming
    }
}

public struct PermissionRecord: Hashable, Sendable, Codable {
    public var request: ACPPermissionRequest
    /// The chosen option once resolved (nil option = cancelled).
    public var resolution: Resolution?

    public enum Resolution: Hashable, Sendable, Codable {
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
    /// The Mac holds older records than the oldest it sent (``AgentSessionEvent/earlierHistory(_:)``).
    @ObservationIgnored private var sourceHasEarlier = false
    /// An older page is being read (``loadEarlier()``).
    public private(set) var isLoadingEarlier = false
    /// The source is still reading the chat's history from the Mac
    /// (``AgentSessionSource/loadsHistory``, then ``AgentSessionEvent/historyLoading(_:)``). With no
    /// turns yet the chat shows a loading state, never the empty new-chat screen; with turns it
    /// shows them (kept from before) and says it is updating.
    public private(set) var isLoadingHistory = false
    /// The chat is new: it holds no turns and none are on their way (the empty state shows).
    public var isNewChat: Bool { !hasTurns && !isLoadingHistory }
    /// The title the agent gave the session (`session_info_update`).
    public private(set) var sessionTitle: String?
    /// Each ended turn's `turn_result` record seq, by turn id: the turn a fork through it keeps
    /// (Edit and Resend of an earlier prompt).
    public private(set) var turnSeqs: [String: Int] = [:]
    /// Each turn's prompt (`user_message`) record seq, by turn id: what a bookmark on it marks.
    public private(set) var promptSeqs: [String: Int] = [:]
    /// The record seqs the chat's bookmarks (prompts) and pins (answers) mark, as acpmux keeps
    /// them (`_acpmux/bookmark_get`, its `bookmarks` record).
    public private(set) var bookmarkedSeqs: Set<Int> = []
    /// The newest permission answer this phone sent, until the Mac decides that ask
    /// (Check and Retry Permission sends it again when its reply was lost).
    @ObservationIgnored private var sentPermissionAnswer: (permissionID: String, optionID: String?)?
    /// The newest call the chat made was that answer (its error, if one comes, is the answer's).
    @ObservationIgnored private var awaitsPermissionReply = false
    /// The newest answer failed to reach the Mac while its ask stays open.
    public private(set) var permissionAnswerUncertain = false
    /// acpmux holds the waiting prompts (`queue_paused`) until the person resumes them.
    public private(set) var queuePaused = false
    /// The pause's reason as acpmux logged it (`stop`: a person's Stop held agent messages).
    public private(set) var queuePauseReason: String?

    /// The chat's title: the agent's session title, else the session's name, else (a new
    /// session) the first prompt trimmed to 40 characters, as ChatGPT and Claude do.
    public var displayTitle: String {
        Self.chatTitle(sessionTitle: sessionTitle, name: summary.name, firstPrompt: firstPrompt)
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
    /// The allow option on its way (nil otherwise).
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
    /// Whether the last failed prompt can be sent again from the composer.
    public var canRetryPrompt: Bool { resendable != nil }
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
    /// Retained output belongs to the failed attempt, even when chunks carry no message ID.
    private var startsNewAttempt = false
    /// The turn the latest `userMessage` opened (nil for a steer into a running turn): the one a `promptFrom` may mark.
    @ObservationIgnored private var promptedTurnID: String?
    /// The steer the latest `userMessage` put into a running turn: the one a `promptFrom` may mark.
    @ObservationIgnored private var steeredPrompt: (turnID: String, promptID: String)?
    private var task: Task<Void, Never>?
    /// The chat's edit diffs, computed once each off the main thread (the transcript, its
    /// grid card and the subagent screens share them).
    @ObservationIgnored public let diffs = ChatDiffCache()

    public init(source: any AgentSessionSource) {
        self.source = source
        self.summary = source.summary
        self.isLoadingHistory = source.loadsHistory
        let stream = source.events()
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.receive(event)
            }
        }
    }

    isolated deinit {
        task?.cancel()
        chunkFlush?.cancel()
        spill?.discard()
    }

    // MARK: Derived state
    //
    // Read by views that must not redraw per streamed token (the composer, the
    // toolbar, the transcript's host): each is stored and written only when its value
    // changes, after every applied event, so observing it costs nothing while text streams.

    /// The chat has turns (the empty state is gone).
    public private(set) var hasTurns = false
    /// The newest turn is running.
    public private(set) var isRunning = false
    /// The first turn's prompt (the title of an untitled chat).
    public private(set) var firstPrompt: String?
    /// An edit by the agent in any turn ("Agent Edits").
    public private(set) var hasAgentEdits = false
    /// The newest turn's open permission request.
    public private(set) var pendingPermission: PermissionRecord?
    /// The newest turn's open question.
    public private(set) var pendingQuestion: AgentQuestion?
    /// The chat's open sudo card (acpmux `elevation_request`), until it is answered or closed.
    public private(set) var pendingElevation: AgentElevationAsk?
    /// The sudo card's Approve is being signed and sent.
    public private(set) var sendingElevation = false
    /// The running turn's latest plan.
    public private(set) var runningPlanEntries: [ACPPlanEntry]?
    /// Turns before the newest that hold an edit (counted once per new turn).
    @ObservationIgnored private var editsBeforeLast: (count: Int, any: Bool) = (0, false)

    /// `lastTurnOnly`: only the newest turn changed (streamed text).
    private func refreshDerived(lastTurnOnly: Bool = false) {
        let last = turns.last
        assign(\.hasTurns, !turns.isEmpty)
        assign(\.isRunning, last?.status == .running)
        assign(\.firstPrompt, spilledFirstPrompt ?? turns.first?.prompt)
        assign(\.pendingPermission, last.flatMap(Self.openPermission))
        assign(\.pendingQuestion, last.flatMap(Self.openQuestion))
        assign(\.runningPlanEntries, last?.status == .running ? last.flatMap(Self.latestPlan) : nil)
        let earlier = max(turns.count - 1, 0)
        if editsBeforeLast.count != earlier || (!lastTurnOnly && !editsBeforeLast.any) {
            editsBeforeLast = (earlier, turns.dropLast().contains(where: \.hasEdits))
        }
        assign(\.hasAgentEdits, editsBeforeLast.any || last?.hasEdits == true)
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AgentChatStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    nonisolated static func openPermission(_ turn: AgentTurn) -> PermissionRecord? {
        for case .permission(let record) in turn.items.reversed() where record.resolution == nil {
            return record
        }
        return nil
    }

    nonisolated static func openQuestion(_ turn: AgentTurn) -> AgentQuestion? {
        for case .question(let question) in turn.items.reversed() where question.isPending {
            return question
        }
        return nil
    }

    nonisolated static func latestPlan(_ turn: AgentTurn) -> [ACPPlanEntry]? {
        for item in turn.items.reversed() {
            if case .plan(_, let entries) = item { return entries }
        }
        return nil
    }

    // MARK: Streamed chunks, one store change per frame

    /// Text chunks that arrived since the last frame, applied together at the next one
    /// (`flushChunks`), so a burst of tokens is one change to `turns`. Any other event
    /// applies them first, so the order of events never changes.
    @ObservationIgnored private var pendingChunks: [AgentSessionEvent] = []
    @ObservationIgnored private var chunkFlush: Task<Void, Never>?
    /// Waits for the next display frame. nil applies every event at once (tests, macOS).
    @ObservationIgnored var nextFrame: (@MainActor () async -> Void)? = AgentChatStore.defaultNextFrame
    /// Coalesced applies (tests: one per frame, not one per chunk).
    @ObservationIgnored private(set) var chunkFlushes = 0

    func receive(_ event: AgentSessionEvent) {
        guard let nextFrame, Self.isTextChunk(event) else {
            flushChunks()
            apply(event)
            return
        }
        pendingChunks.append(event)
        guard chunkFlush == nil else { return }
        chunkFlush = Task { [weak self] in
            await nextFrame()
            self?.flushChunks()
        }
    }

    /// Applies the waiting chunks now (a merged run of one message's chunks is one append).
    func flushChunks() {
        chunkFlush?.cancel()
        chunkFlush = nil
        guard !pendingChunks.isEmpty else { return }
        let chunks = pendingChunks
        pendingChunks = []
        chunkFlushes += 1
        for chunk in Self.merged(chunks) { applyEvent(chunk) }
        refreshDerived(lastTurnOnly: true)
    }

    nonisolated static func isTextChunk(_ event: AgentSessionEvent) -> Bool {
        switch event {
        case .update(.agentMessageChunk), .update(.agentThoughtChunk): true
        default: false
        }
    }

    /// Consecutive chunks of the same message (or of thinking) joined into one.
    nonisolated static func merged(_ chunks: [AgentSessionEvent]) -> [AgentSessionEvent] {
        var out: [AgentSessionEvent] = []
        for chunk in chunks {
            switch (out.last, chunk) {
            case (.update(.agentMessageChunk(let text, let id))?, .update(.agentMessageChunk(let more, let nextID))) where id == nextID:
                out[out.count - 1] = .update(.agentMessageChunk(text: text + more, messageId: id))
            case (.update(.agentThoughtChunk(let text))?, .update(.agentThoughtChunk(let more))):
                out[out.count - 1] = .update(.agentThoughtChunk(text: text + more))
            default:
                out.append(chunk)
            }
        }
        return out
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
        // One of the agent's own slash commands waits for the turn and runs as its own.
        let steers = steer && !Self.commandWaitsForTurn(text, harness: summary.harness, commands: availableCommands)
        source.send(.prompt(text: text, attachments: attachments, steer: steers,
                            promptID: promptID, resend: resend != nil))
    }

    /// Whether `text` is one of a Claude agent's own slash commands (`commands`, its
    /// `available_commands_update`: built-ins, skills, plugin commands such as `/loop`), the Mac's
    /// `commandWaitsForTurn`. Claude Code never reads a command into a running turn: steered, it
    /// waits under the turn unread, or is read as plain words. Such a message queues and runs as
    /// its own turn. Text that only starts with a slash (a path, a word the agent doesn't list)
    /// is the agent's to read, and steers.
    nonisolated static func commandWaitsForTurn(_ text: String, harness: String, commands: [ACPAvailableCommand]) -> Bool {
        guard family(of: harness) == "claude", !commands.isEmpty else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let name = trimmed.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        return !name.isEmpty && commands.contains { $0.name.lowercased() == name }
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

    /// A failed latest turn retries through acpmux, which preserves its input and context.
    public func canRetryFailedTurn(_ turn: AgentTurn) -> Bool {
        turns.last?.id == turn.id && turns.last?.status == .failed && !retryRequested
    }

    public func retryFailedTurn(_ turn: AgentTurn) {
        guard canRetryFailedTurn(turn) else { return }
        clientError = nil
        retryRequested = true
        source.send(.retryFailedTurn)
    }

    private var retryRequested = false

    public func cancel() { source.send(.cancel) }

    public func respond(to request: ACPPermissionRequest, option: ACPPermissionOption?) {
        // A refusal is about the previous answer ("Approve this on your Mac"):
        // a new answer, such as the decline that follows, replaces it.
        clientError = nil
        // An allow is signed with the approval key: the bar shows "Sending…" until the
        // decision lands or the signature fails.
        approvingOptionID = option?.isAllow == true ? option?.id : nil
        sentPermissionAnswer = (request.id, option?.id)
        permissionAnswerUncertain = false
        awaitsPermissionReply = true
        source.send(.respondPermission(permissionId: request.id, optionId: option?.id))
    }

    /// Answers the sudo card: Approve with the password (signed with the approval key), or Deny.
    /// The card stays until acpmux records its decision; a failed send says why (``clientError``).
    public func answerElevation(_ ask: AgentElevationAsk, password: String?) {
        clientError = nil
        sendingElevation = password != nil
        source.send(.answerElevation(ask, password: password.map(AgentSecretText.init)))
    }

    // MARK: Bookmarks, pins and permissions (chat polish parity)

    /// The prompt's bookmark (the Mac's thread minimap "Bookmark this turn").
    public func isBookmarked(_ turn: AgentTurn) -> Bool {
        promptSeqs[turn.id].map(bookmarkedSeqs.contains) ?? false
    }

    /// The answer's pin (the Mac's message row "Pin"): its `turn_result` record marked.
    public func isPinned(_ turn: AgentTurn) -> Bool {
        turnSeqs[turn.id].map(bookmarkedSeqs.contains) ?? false
    }

    /// Whether the prompt can be bookmarked: acpmux logged it (a replay's chat has none).
    public func canBookmark(_ turn: AgentTurn) -> Bool { !source.isReadOnly && promptSeqs[turn.id] != nil }
    /// Whether the answer can be pinned: its turn ended.
    public func canPin(_ turn: AgentTurn) -> Bool { !source.isReadOnly && turnSeqs[turn.id] != nil }

    public func toggleBookmark(_ turn: AgentTurn) {
        guard let seq = promptSeqs[turn.id] else { return }
        setMark(seq, on: !bookmarkedSeqs.contains(seq))
    }

    public func togglePin(_ turn: AgentTurn) {
        guard let seq = turnSeqs[turn.id] else { return }
        setMark(seq, on: !bookmarkedSeqs.contains(seq))
    }

    /// Shows the mark at once; acpmux's `bookmarks` record (every mark after a change) is what
    /// stays. A refusal undoes this one mark only, so another change made meanwhile is kept.
    private func setMark(_ seq: Int, on: Bool) {
        if on { bookmarkedSeqs.insert(seq) } else { bookmarkedSeqs.remove(seq) }
        let source = source
        Task { @MainActor [weak self] in
            do {
                _ = try await source.setBookmark(seq: seq, bookmarked: on)
            } catch {
                guard let self else { return }
                if on { self.bookmarkedSeqs.remove(seq) } else { self.bookmarkedSeqs.insert(seq) }
                self.clientError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }

    /// Reads the chat's marks (the Mac's pane loads them on open): once it is read, later
    /// changes come as `bookmarks` records. A read that fails (the link was not up yet) is made
    /// again when the chat connects.
    public func loadBookmarks() {
        guard !loadedBookmarks, !loadingBookmarks, summary.status != .disconnected else { return }
        loadingBookmarks = true
        let source = source
        Task { @MainActor [weak self] in
            let marks = try? await source.bookmarks()
            guard let self else { return }
            self.loadingBookmarks = false
            guard let marks else { return }
            self.loadedBookmarks = true
            self.bookmarkedSeqs = Set(marks)
        }
    }

    @ObservationIgnored private var loadedBookmarks = false
    @ObservationIgnored private var loadingBookmarks = false
    /// The transcript asked for the marks (it is on screen): a reconnect reads them if needed.
    @ObservationIgnored private var wantsBookmarks = false

    /// The chat is on screen: its marks are read now, or when it connects.
    public func showBookmarks() {
        wantsBookmarks = true
        loadBookmarks()
    }

    /// The turns the transcript holds, for Previous/Next Turn; `bookmarkedOnly`: only those
    /// whose prompt is bookmarked (Previous/Next Bookmarked Prompt).
    public func navigableTurns(bookmarkedOnly: Bool) -> [AgentTurn] {
        bookmarkedOnly ? turns.filter(isBookmarked) : turns
    }

    /// Check and Retry Permission: the answer that did not reach the Mac goes again while
    /// its ask is still open; when the ask is gone the open asks are read again instead.
    public func checkAndRetryPermission() {
        guard let sent = sentPermissionAnswer, let pending = pendingPermission, pending.request.id == sent.permissionID else {
            permissionAnswerUncertain = false
            sentPermissionAnswer = nil
            awaitsPermissionReply = false
            source.refreshPermissions()
            return
        }
        awaitsPermissionReply = true
        clientError = nil
        permissionAnswerUncertain = false
        approvingOptionID = pending.request.options.first { $0.id == sent.optionID }?.isAllow == true ? sent.optionID : nil
        source.send(.respondPermission(permissionId: sent.permissionID, optionId: sent.optionID))
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

    /// Retry on a finished turn: its prompt goes again with what it attached. An image only
    /// the Mac's record holds is read back first; one that can't be read goes without its
    /// bytes, so the send fails and the draft comes back instead of a prompt without it.
    public func retry(_ turn: AgentTurn) {
        withAttachments(of: turn) { $0.send(prompt: turn.prompt, attachments: $1) }
    }

    /// Retry with another model (the Mac's turn menu): the chat moves to `model`, then `turn`'s
    /// prompt goes again with its attachments; the model the chat runs retries as Retry does.
    /// When the Mac refuses the model, the prompt is not sent and the chat shows the Mac's reason.
    public func retry(_ turn: AgentTurn, model: String) {
        let text = turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !turn.attachments.isEmpty else { return }
        withAttachments(of: turn) { store, attachments in
            guard model != store.currentModelID else { return store.send(prompt: text, attachments: attachments) }
            store.clientError = nil
            let promptID = UUID().uuidString.lowercased()
            store.keepSent(attachments, promptID: promptID)
            store.source.send(.retryWithModel(model: model, text: text, attachments: attachments, promptID: promptID))
        }
    }

    /// Runs `then` with `turn`'s attachments holding their bytes: at once when the phone has
    /// them all, else after reading recorded images from the source.
    private func withAttachments(of turn: AgentTurn, then: @escaping @MainActor (AgentChatStore, [AgentAttachment]) -> Void) {
        let attachments = turn.attachments
        guard attachments.contains(where: { $0.data == nil && $0.fileURL == nil }) else { return then(self, attachments) }
        Task { [weak self] in
            var loaded = attachments
            for index in loaded.indices where loaded[index].data == nil && loaded[index].fileURL == nil {
                guard let source = self?.source else { return }
                loaded[index].data = await source.attachmentData(loaded[index])
            }
            guard let self else { return }
            then(self, loaded)
        }
    }

    /// The models Retry with another model offers (the Mac shows it only with two or more).
    public var retryModels: [ACPModelInfo] { models.count > 1 ? models : [] }
    public func setMode(_ id: String) { source.send(.setMode(id)) }
    public func setConfig(_ id: String, value: String) { source.send(.setConfigOption(id: id, value: value)) }
    public func removeQueued(_ id: String) { source.send(.removeQueued(promptId: id)) }

    /// The user bubble's Edit and Resend: returns the text the composer gets to edit. It
    /// sends nothing; the message goes when the person sends it from the composer. Only an
    /// empty composer (whitespace counts as empty) takes it: a draft there is never replaced,
    /// so this returns nil (the bubble then asks before replacing it).
    public func editAndResend(_ turn: AgentTurn, draft: String) -> String? {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return turn.prompt
    }

    /// The turn an edit of `turn`'s prompt forks through (the Mac's Edit and Resend, webviews
    /// conversation/editPrompt.ts): the seq of the completed turn right before it, or nil when
    /// its prompt can't be edited that way. A chat's first prompt has no turn before it; a
    /// failed or cancelled turn before it was never answered whole; only Claude and Codex
    /// chats fork through an earlier turn (acpmux `fork_through.rs`).
    public func editForkSeq(for turn: AgentTurn) -> Int? {
        guard ["claude", "codex"].contains(Self.family(of: summary.harness)),
              let index = turns.firstIndex(where: { $0.id == turn.id }), !turn.prompt.isEmpty else { return nil }
        guard index > 0 else {
            // The turn before it is on disk (`spillOlder`).
            guard turnsOnDisk > 0, let spilled = spilledTurns.last, spilled.completed else { return nil }
            return turnSeqs[spilled.id]
        }
        let before = turns[index - 1]
        guard before.status == .completed else { return nil }
        return turnSeqs[before.id]
    }

    /// The harness family acpmux forks by: Claude Code's profiles (`claude-sr`, `cmux`) are Claude's.
    nonisolated static func family(of harness: String) -> String {
        let id = harness.lowercased()
        if id == "claude" || id.hasPrefix("claude-") || id == "cmux" { return "claude" }
        if id == "codex" || id.hasPrefix("codex-") { return "codex" }
        return id
    }

    /// Resume (the Mac's Resume over a paused queue): acpmux runs the held prompts again.
    public func resumeQueue() {
        guard queuePaused else { return }
        source.send(.resumeQueue)
    }

    /// The queued row's X: takes the prompt back into the composer, returning the text the
    /// composer gets. Only an empty composer (whitespace counts as empty) takes it: a draft
    /// there is never replaced, so the prompt stays queued and this returns nil (the row then
    /// asks before removing it).
    public func takeBackQueued(_ id: String, draft: String) -> String? {
        guard let item = queue.first(where: { $0.id == id }) else { return nil }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        removeQueued(id)
        return item.text
    }
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
        applyEvent(event)
        refreshDerived()
    }

    private func applyEvent(_ event: AgentSessionEvent) {
        if !spilledTurnIDs.isEmpty, replaysSpilledTurn(event) { return }
        revision &+= 1
        lastChangeWasReplay = false
        placeBottomStackInstantly = false
        if gapFiller != nil { noteNewer(event) }
        switch event {
        case .turnRetried(let previousTurnID, let turnID):
            guard let index = turns.indices.last, turns[index].id == previousTurnID,
                  turns[index].status == .failed else { break }
            // Keep the original input and partial work: the daemon may continue a cut turn.
            // Its new user_message is an attempt, not another user-authored turn.
            turns[index].id = turnID
            turns[index].status = .running
            turns[index].errorText = nil
            turns[index].retry = nil
            turns[index].endedAt = nil
            for agentIndex in subagents.indices where subagents[agentIndex].turnID == previousTurnID {
                subagents[agentIndex].turnID = turnID
            }
            // The gap goes in before this turn whatever it is called now.
            if gapBeforeTurnID == previousTurnID { gapBeforeTurnID = turnID }
            retryRequested = false
            currentMessageID = nil
            startsNewAttempt = true
        case .userMessage(let text, let promptId, let turnId, let attachments, let at):
            retryRequested = false
            currentMessageID = nil
            reached(promptId)
            if gapFiller != nil { gapLeftQueue.insert(promptId) }
            // A steer into a running turn shares its id: only the message that opened the turn is its prompt.
            promptedTurnID = nil
            steeredPrompt = nil
            // A turn on disk (`spillOlder`) is not new: a replay that brings its prompt again
            // must not add it a second time, at the bottom.
            if let index = turns.firstIndex(where: { $0.id == turnId }) {
                // Another prompt id is a message steered in: it draws where it went in (once, a
                // replay brings it again). A retried attempt's message is not one.
                if !startsNewAttempt, let opened = turns[index].promptID, opened != promptId,
                   !turns[index].items.contains(where: { if case .steer(let m) = $0 { m.promptID == promptId } else { false } }) {
                    let sent = Self.sentAttachments(sentAttachments[promptId], recorded: attachments)
                    turns[index].items.append(.steer(SteeredMessage(promptID: promptId, text: text, attachments: sent, at: at)))
                    steeredPrompt = (turnId, promptId)
                }
            } else if !spilledTurnIDs.contains(turnId) {
                // A steer the turn ended before the agent read it runs as this turn's prompt, under
                // its own id (acpmux `steer_end.rs`): it draws once, here, not also as a steer in
                // the turn before.
                if let last = turns.indices.last {
                    turns[last].items.removeAll { if case .steer(let m) = $0 { m.promptID == promptId } else { false } }
                }
                promptedTurnID = turnId
                startsNewAttempt = false
                turns.append(AgentTurn(id: turnId, prompt: text, promptID: promptId,
                                       attachments: Self.sentAttachments(sentAttachments[promptId], recorded: attachments),
                                       promptAt: at))
            }
            // The turn holds them now.
            sentAttachments[promptId] = nil
        case .queued(let text, let promptId, _):
            reached(promptId)
            // A steer that lost a stop race waits in the queue now (the Mac's `dropDeferredSteer`):
            // it is drawn there, not also in the turn it missed.
            if let last = turns.indices.last {
                turns[last].items.removeAll { if case .steer(let m) = $0 { m.promptID == promptId } else { false } }
            }
            queue.append(QueuedPrompt(id: promptId, text: text))
        case .dequeued(let promptId):
            queue.removeAll { $0.id == promptId }
            if gapFiller != nil { gapLeftQueue.insert(promptId) }
        case .queueUpdated(let promptId, let text):
            // Newer than any edit the gap holds, whether or not the gap showed the prompt yet.
            if gapFiller != nil { gapLaterQueueText[promptId] = text }
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
        case .turnSeq(let turnId, let seq):
            turnSeqs[turnId] = seq
        case .promptFrom(let turnId, let incoming):
            if let steered = steeredPrompt, steered.turnID == turnId {
                // Another agent's message steered in: its card, in the turn, under its sender.
                mutateTurn(turnId) { turn in
                    for index in turn.items.indices {
                        if case .steer(var message) = turn.items[index], message.promptID == steered.promptID {
                            message.incoming = incoming
                            turn.items[index] = .steer(message)
                        }
                    }
                }
                return
            }
            guard promptedTurnID == turnId else { return }
            mutateTurn(turnId) { $0.incoming = incoming }
        case .promptSeq(let turnId, let seq):
            promptSeqs[turnId] = seq
        case .bookmarks(let seqs):
            bookmarkedSeqs = Set(seqs)
        case .queuePaused(let paused, let reason):
            queuePaused = paused
            queuePauseReason = paused ? reason : nil
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
            if sentPermissionAnswer?.permissionID == permissionId {
                sentPermissionAnswer = nil
                permissionAnswerUncertain = false
                awaitsPermissionReply = false
            }
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
            summary.status = turns.last?.status == .running ? .running : .idle
        case .elevationRequest(let ask):
            pendingElevation = ask
            sendingElevation = false
            summary.status = .waiting
        case .elevationDecision(let id):
            guard pendingElevation?.id == id else { break }
            pendingElevation = nil
            sendingElevation = false
            summary.status = turns.last?.status == .running ? .running : .idle
        case .questionAnswered(let questionId, let answer):
            decidedAsks.insert(questionId)
            updateItems { item in
                guard case .question(var question) = item, question.id == questionId else { return nil }
                question.state = .answered(answer)
                return .question(question)
            }
            summary.status = turns.last?.status == .running ? .running : .idle
        case .modelsAvailable(let models, let current):
            self.models = models
            currentModelID = current
        case .modesAvailable(let modes, let current):
            offeredModes = modes
            self.modes = ACPMode.phoneChoices(modes, current: current, fullAccess: fullAccess)
            currentModeID = current
        case .earlierHistory(let earlier):
            sourceHasEarlier = earlier
            refreshEarlierHistory()
        case .historyLoading(let loading):
            if isLoadingHistory != loading { isLoadingHistory = loading }
        case .earlierPage(let events, let hasEarlier):
            isLoadingEarlier = false
            sourceHasEarlier = hasEarlier
            refreshEarlierHistory()
            prependEarlier(events)
        case .gapOpened(let beforeTurnID):
            openGap(before: beforeTurnID)
        case .gapPage(let events, let done):
            fillGap(events, done: done)
        case .fullAccess(let on):
            fullAccess = on
            modes = ACPMode.phoneChoices(offeredModes, current: currentModeID, fullAccess: on)
        case .status(let status):
            summary.status = status
            if status != .disconnected, wantsBookmarks { loadBookmarks() }
            // A dropped link can lose the request before the daemon accepts it, with
            // no error or retry record to clear the in-flight tap on reattach.
            if status == .disconnected { retryRequested = false }
        case .clientError(let message):
            approvingOptionID = nil
            sendingElevation = false
            // The error that follows an answer whose ask is still open: it did not reach the
            // Mac (or its reply was lost). Another call's error says nothing about it.
            if awaitsPermissionReply, let sent = sentPermissionAnswer, pendingPermission?.request.id == sent.permissionID {
                permissionAnswerUncertain = true
            }
            awaitsPermissionReply = false
            retryRequested = false
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
            for event in events { applyEvent(event) }
            inSpilledTurn = false
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

    /// The reader reached the oldest turn shown: the source reads the page before it.
    public func loadEarlier() {
        guard hasEarlierHistory, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        // Turns this phone spilled are newer than anything the Mac has not sent yet: they come
        // back first, from disk, and only then does the Mac read further back.
        if let spill, turnsOnDisk > 0 {
            Task { @MainActor [weak self] in
                let page = await spill.pop()
                self?.restoreSpilled(page)
            }
            return
        }
        source.loadEarlierHistory()
    }

    /// `loadEarlier` for a page on disk, returning once it is shown (tests).
    func loadEarlierFromDisk() async {
        guard let spill, turnsOnDisk > 0, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        restoreSpilled(await spill.pop())
    }

    // MARK: Spill

    /// Turns the chat keeps in memory once the reader is back at the newest (`spillOlder`).
    public static let windowKeep = 80
    /// The chat spills only past this many turns, so a reader at the bottom does not spill a
    /// turn per new turn.
    public static let windowTrigger = 120
    /// Turns kept on a memory warning (with the reader's own and those after it).
    public static let pressureKeep = 20

    /// Older turns that left memory, on disk while the app runs (`RowSpill`), made on the first
    /// spill. Each store has its own folder, deleted with it.
    @ObservationIgnored private(set) var spill: RowSpill<AgentTurn>?
    /// Turns in the spill.
    public private(set) var turnsOnDisk = 0
    /// A replay is going through a turn on disk: its records (a source that replays the whole
    /// log, a reattach) are not applied to the turn shown last.
    @ObservationIgnored private var inSpilledTurn = false

    /// Whether `event` belongs to a turn on disk, which a replay brings again: it is skipped,
    /// so the turn is neither added a second time at the bottom nor written into another.
    private func replaysSpilledTurn(_ event: AgentSessionEvent) -> Bool {
        switch event {
        case .userMessage(_, _, let turnId, _, _):
            inSpilledTurn = spilledTurnIDs.contains(turnId)
            return inSpilledTurn
        case .turnStarted(let turnId, _), .turnResult(let turnId, _, _, _), .turnSeq(let turnId, _),
             .promptSeq(let turnId, _), .promptFrom(let turnId, _):
            return spilledTurnIDs.contains(turnId)
        case .update:
            return inSpilledTurn
        default:
            return false
        }
    }
    /// Their ids.
    @ObservationIgnored private var spilledTurnIDs: Set<String> = []
    /// The untitled chat's title, when its first turn is on disk. ("Agent Edits" covers the
    /// turns in memory, as it covers only the pages read from the Mac.)
    @ObservationIgnored private var spilledFirstPrompt: String?
    /// Each turn on disk, oldest first, with whether it completed: Edit and Resend of the
    /// oldest turn in memory forks through the newest of them.
    @ObservationIgnored private var spilledTurns: [(id: String, completed: Bool)] = []
    /// Makes the spill (tests put it in their own folder).
    @ObservationIgnored public var makeSpill: @MainActor () -> RowSpill<AgentTurn> = {
        // Turns are heavy (tool output, diffs): small pages. The cap is far above any chat, so
        // the spill never leaves a gap between what it holds and what the Mac still has.
        .forThisRun("agent-chat", scope: UUID().uuidString, pageSize: 20, maxRows: 100_000)
    }

    private func refreshEarlierHistory() {
        assign(\.hasEarlierHistory, sourceHasEarlier || turnsOnDisk > 0)
    }

    /// Moves the oldest turns to disk, keeping the newest `keeping` and every turn from
    /// `protecting` (the reader's first visible turn) on. A running turn and one with an open
    /// ask, and every turn after it, stay. Scrolling up brings them back (`loadEarlier`).
    @discardableResult
    public func spillOlder(keeping: Int, protecting: String? = nil) -> Int {
        // A page on its way (from disk or the Mac) goes in front of the turns shown: spilling
        // now would put newer turns on disk below it, and bring them back above it. A gap
        // being filled goes in among them: the turns around it stay until it is filled.
        guard !isLoadingEarlier, gapFiller == nil else { return 0 }
        var end = turns.count - keeping
        if let protecting, let index = turns.firstIndex(where: { $0.id == protecting }) { end = min(end, index) }
        if let live = turns.prefix(max(end, 0)).firstIndex(where: { turn in
            turn.status == .running || Self.openPermission(turn) != nil || Self.openQuestion(turn) != nil
        }) {
            end = min(end, live)
        }
        guard end > 0 else { return 0 }
        let spill = spill ?? makeSpill()
        self.spill = spill
        let older = Array(turns.prefix(end))
        if turnsOnDisk == 0, !sourceHasEarlier { spilledFirstPrompt = older.first?.prompt }
        spilledTurns += older.map { ($0.id, $0.status == .completed) }
        spill.push(older.reversed())
        diffs.forget(older)
        spilledTurnIDs.formUnion(older.map(\.id))
        turnsOnDisk += older.count
        turns.removeFirst(end)
        revision &+= 1
        refreshEarlierHistory()
        refreshDerived()
        return end
    }

    /// A page of spilled turns (newest first) goes back in front of the shown ones.
    private func restoreSpilled(_ page: [AgentTurn]) {
        isLoadingEarlier = false
        turnsOnDisk = page.isEmpty ? 0 : max(0, turnsOnDisk - page.count)
        spilledTurnIDs.subtract(page.map(\.id))
        spilledTurns.removeLast(min(page.count, spilledTurns.count))
        if turnsOnDisk == 0 {
            spilledTurnIDs = []
            spilledTurns = []
            spilledFirstPrompt = nil
        }
        let shown = Set(turns.map(\.id))
        let back = page.reversed().filter { !shown.contains($0.id) }
        if !back.isEmpty {
            turns.insert(contentsOf: back, at: 0)
            for turn in back {
                replayedIDs.insert(turn.id)
                for row in turn.rows { replayedIDs.insert(row.id) }
            }
            lastChangeWasReplay = true
            revision &+= 1
        }
        refreshEarlierHistory()
        refreshDerived()
    }

    /// Older turns go in front of the shown ones. They are built on their own: the queue, the
    /// asks and the status the chat shows are newer than anything in them. Drawn in place, as
    /// history.
    private func prependEarlier(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        let older = AgentChatStore(source: EarlierHistorySource(summary: summary))
        older.nextFrame = nil
        older.apply(.batch(events))
        turnSeqs.merge(older.turnSeqs) { current, _ in current }
        promptSeqs.merge(older.promptSeqs) { current, _ in current }
        let shown = Set(turns.map(\.id))
        let added = older.turns.filter { !shown.contains($0.id) }
        guard !added.isEmpty else { return }
        turns.insert(contentsOf: added, at: 0)
        let known = Set(subagents.map(\.id))
        subagents.insert(contentsOf: older.subagents.filter { !known.contains($0.id) }, at: 0)
        for turn in added {
            replayedIDs.insert(turn.id)
            for row in turn.rows { replayedIDs.insert(row.id) }
        }
        lastChangeWasReplay = true
    }

    // MARK: Reconnect gap (tail-first)

    /// A reattach after a long time away showed the newest records first; the records between
    /// what the chat had and them are being read, and go in just before ``gapBeforeTurnID`` as
    /// they come (``AgentSessionEvent/gapOpened(beforeTurnID:)``, ``AgentSessionEvent/gapPage(_:done:)``).
    public private(set) var isFillingGap = false
    /// The first turn of the newest records while the gap before it fills (nil: no gap).
    public private(set) var gapBeforeTurnID: String?
    /// The gap's turns, built on their own from the turn the chat had last (continued by the
    /// gap's first records) as its pages come: the queue, the asks and the status the chat
    /// shows are newer than anything in it.
    @ObservationIgnored private var gapFiller: AgentChatStore?
    /// How many of the filler's turns are shown now, just before `gapBeforeTurnID`.
    @ObservationIgnored private var gapShown = 0
    /// The newer records (the newest page, live ones) that change what the gap also writes, in
    /// the order they came: subagent records, answers to asks, the queue's order. The gap's
    /// records are older than all of them, so each page's result is the gap's state with these
    /// applied again on top, never a merge that guesses which part of an item is whose (a
    /// message or tool call goes on across the gap's edge).
    @ObservationIgnored private var gapNewerAgentEvents: [AgentSessionEvent] = []
    @ObservationIgnored private var gapNewerDecisions: [AgentSessionEvent] = []
    @ObservationIgnored private var gapLaterQueueOrder: [String]?
    /// While a gap fills: prompts that newer records took out of the queue (they ran or were
    /// removed), the newest text a newer edit gave a prompt not shown yet, and the waiting
    /// prompts the gap put in the queue.
    @ObservationIgnored private var gapLeftQueue: Set<String> = []
    @ObservationIgnored private var gapLaterQueueText: [String: String] = [:]
    @ObservationIgnored private var gapQueued: Set<String> = []
    /// The prompts waiting when the gap opened: they waited longest, so a prompt the gap puts
    /// back goes after them.
    @ObservationIgnored private var gapPriorQueued: Set<String> = []
    /// Every subagent the chat had when the gap opened, as it was then: the gap's records may
    /// go on with one started in any earlier turn (a background agent outlives its turn), so
    /// the filler starts from all of them, and only those the gap changed are taken back.
    @ObservationIgnored private var gapSeedAgents: [String: AgentSubagent] = [:]

    private func noteNewer(_ event: AgentSessionEvent) {
        switch event {
        case .subagent, .subagentUpdate: gapNewerAgentEvents.append(event)
        case .permissionDecision, .questionAnswered: gapNewerDecisions.append(event)
        case .queueOrder(let order): gapLaterQueueOrder = order
        default: break
        }
    }

    /// A prompt the gap says left the queue (ran or was removed).
    private func leaveQueueFromGap(_ promptId: String) {
        queue.removeAll { $0.id == promptId }
        gapQueued.remove(promptId)
        gapLeftQueue.insert(promptId)
    }

    private func openGap(before turnID: String) {
        if gapFiller != nil { closeGap() }
        let filler = AgentChatStore(source: EarlierHistorySource(summary: summary))
        filler.nextFrame = nil
        if let last = turns.last {
            // The gap's first records may continue this turn (its answer, its result).
            filler.turns = [last]
            filler.currentMessageID = currentMessageID
        }
        filler.subagents = subagents
        gapSeedAgents = Dictionary(subagents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        gapPriorQueued = Set(queue.map(\.id))
        // What this phone sent with a prompt that ran in the gap.
        filler.sentAttachments = sentAttachments
        gapFiller = filler
        gapShown = filler.turns.count
        gapBeforeTurnID = turnID
        isFillingGap = true
    }

    private func fillGap(_ events: [AgentSessionEvent], done: Bool) {
        guard let filler = gapFiller, let before = gapBeforeTurnID else { return }
        if !events.isEmpty {
            let previous = filler.turns.count
            for event in events {
                // What the gap says about the chat as a whole, where the newer records cannot
                // have said it again: a prompt this phone sent ran (or waited), one shown waiting
                // left the queue, a sudo card shown was answered.
                switch event {
                case .userMessage(_, let promptId, _, _, _):
                    reached(promptId)
                    sentAttachments[promptId] = nil
                    leaveQueueFromGap(promptId)
                case .queued(let text, let promptId, _):
                    reached(promptId)
                    // Still waiting unless a newer record says it left the queue: it goes in
                    // ahead of what the newest records queued (it waited longer), with the
                    // newest text the chat has for it.
                    if !gapLeftQueue.contains(promptId), !queue.contains(where: { $0.id == promptId }) {
                        let older = gapPriorQueued.union(gapQueued)
                        let place = queue.filter { older.contains($0.id) }.count
                        queue.insert(QueuedPrompt(id: promptId, text: gapLaterQueueText[promptId] ?? text), at: place)
                        gapQueued.insert(promptId)
                    }
                case .dequeued(let promptId):
                    leaveQueueFromGap(promptId)
                case .queueUpdated(let promptId, let text):
                    // An entry waiting before the gap or put in by it (the newest records cannot
                    // queue a prompt the gap edits), unless a newer edit of it came.
                    if gapLaterQueueText[promptId] == nil,
                       let index = queue.firstIndex(where: { $0.id == promptId }) {
                        queue[index].text = text
                    }
                case .permissionDecision(let permissionId, _, _):
                    // An answer this phone sent reached the Mac (its card is in the gap's turn).
                    decidedAsks.insert(permissionId)
                    if sentPermissionAnswer?.permissionID == permissionId {
                        sentPermissionAnswer = nil
                        permissionAnswerUncertain = false
                        awaitsPermissionReply = false
                        approvingOptionID = nil
                    }
                case .questionAnswered(let questionId, _):
                    decidedAsks.insert(questionId)
                case .queueOrder(let order) where gapLaterQueueOrder == nil:
                    // No newer order: the gap's own (what it does not list, the newer
                    // prompts, stays after).
                    let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                    queue.sort { (place[$0.id] ?? .max) < (place[$1.id] ?? .max) }
                case .elevationDecision(let id) where pendingElevation?.id == id:
                    pendingElevation = nil
                    sendingElevation = false
                default:
                    break
                }
                filler.applyEvent(event)
            }
            // An ask the gap showed that a newer record answered: answered in the gap's turn
            // too. The filler must still take a later page's record of an ask answered only
            // newer, so it does not keep these as its own decisions.
            for decision in gapNewerDecisions {
                let id: String
                switch decision {
                case .permissionDecision(let permissionId, _, _): id = permissionId
                case .questionAnswered(let questionId, _): id = questionId
                default: continue
                }
                let had = filler.decidedAsks.contains(id)
                filler.applyEvent(decision)
                if !had { filler.decidedAsks.remove(id) }
            }
            // Prompts the gap put back in the queue take the newer order's places.
            if let order = gapLaterQueueOrder {
                let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                queue.sort { (place[$0.id] ?? .max) < (place[$1.id] ?? .max) }
            }
            if let end = turns.firstIndex(where: { $0.id == before }) {
                let newer = Set(turns[end...].map(\.id))
                let gapTurns = filler.turns.filter { !newer.contains($0.id) }
                let start = max(end - gapShown, 0)
                turns.replaceSubrange(start..<end, with: gapTurns)
                gapShown = gapTurns.count
                turnSeqs.merge(filler.turnSeqs) { _, gap in gap }
                promptSeqs.merge(filler.promptSeqs) { _, gap in gap }
                // Each subagent the gap wrote: the gap's state with every newer record of a
                // subagent applied on top, in order. One the gap started goes before those of
                // the newest turns; one shown already (a newer record made or changed it) is
                // replaced in place.
                let firstNewer = subagents.firstIndex { agent in agent.turnID.map { newer.contains($0) } ?? false } ?? subagents.count
                var rebuiltAgents = filler.subagents
                if !gapNewerAgentEvents.isEmpty, !rebuiltAgents.isEmpty {
                    let rebuilt = AgentChatStore(source: EarlierHistorySource(summary: summary))
                    rebuilt.nextFrame = nil
                    rebuilt.subagents = rebuiltAgents
                    for event in gapNewerAgentEvents { rebuilt.applyEvent(event) }
                    rebuiltAgents = rebuilt.subagents
                }
                // The subagents the gap wrote: those it started, and those of any earlier turn
                // whose state it changed. One it did not touch keeps what the chat shows (it may
                // have newer state already). One the chat had keeps its own turn.
                let gapAgents = Set(filler.subagents.filter { gapSeedAgents[$0.id] != $0 }.map(\.id))
                let gapStarted = gapAgents.subtracting(gapSeedAgents.keys)
                var added: [AgentSubagent] = []
                for agent in rebuiltAgents where gapAgents.contains(agent.id) {
                    if let index = subagents.firstIndex(where: { $0.id == agent.id }) {
                        subagents[index] = agent
                    } else {
                        added.append(agent)
                    }
                }
                subagents.insert(contentsOf: added, at: firstNewer)
                // A newer record that made a subagent the gap started drew it under the newest
                // turn; the gap's turn draws it now.
                for index in (start + gapTurns.count)..<turns.count {
                    turns[index].items = turns[index].items.compactMap { item in
                        guard case .subagents(let group, let ids) = item, ids.contains(where: { gapStarted.contains($0) }) else { return item }
                        let kept = ids.filter { !gapStarted.contains($0) }
                        return kept.isEmpty ? nil : .subagents(id: group, ids: kept)
                    }
                }
                // Drawn in place, as history: the turn continued and the new ones.
                for turn in gapTurns.suffix(max(gapTurns.count - max(previous - 1, 0), 0)) {
                    replayedIDs.insert(turn.id)
                    for row in turn.rows { replayedIDs.insert(row.id) }
                }
                lastChangeWasReplay = true
            }
        }
        if done { closeGap() }
    }

    private func closeGap() {
        gapFiller = nil
        gapShown = 0
        gapNewerAgentEvents = []
        gapNewerDecisions = []
        gapLaterQueueOrder = nil
        gapLeftQueue = []
        gapLaterQueueText = [:]
        gapQueued = []
        gapSeedAgents = [:]
        gapPriorQueued = []
        gapBeforeTurnID = nil
        isFillingGap = false
    }

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
            guard let last = turns.indices.last else { return }
            // Appended in place: the item's string is taken out first, so it has one
            // owner and grows without copying the whole message per chunk.
            if !startsNewAttempt, case .message(let id, var markdown)? = turns[last].items.last, messageId == nil || messageId == currentMessageID || currentMessageID == nil {
                let item = turns[last].items.count - 1
                turns[last].items[item] = .message(id: id, markdown: "")
                markdown += text
                turns[last].items[item] = .message(id: id, markdown: markdown)
            } else {
                turns[last].items.append(.message(id: messageId ?? UUID().uuidString, markdown: text))
            }
            currentMessageID = messageId
            startsNewAttempt = false
        case .agentThoughtChunk(let text):
            guard let last = turns.indices.last else { return }
            if !startsNewAttempt, case .thought(let id, var existing)? = turns[last].items.last {
                let item = turns[last].items.count - 1
                turns[last].items[item] = .thought(id: id, text: "")
                existing += text
                turns[last].items[item] = .thought(id: id, text: existing)
            } else {
                turns[last].items.append(.thought(id: UUID().uuidString, text: text))
            }
            startsNewAttempt = false
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

/// The source a page of older turns is built from on its own (``AgentChatStore/loadEarlier()``):
/// nothing streams and nothing is sent.
@MainActor
private final class EarlierHistorySource: AgentSessionSource {
    let summary: AgentSessionSummary
    init(summary: AgentSessionSummary) { self.summary = summary }
    func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { $0.finish() } }
    func send(_ intent: AgentClientIntent) {}
}
