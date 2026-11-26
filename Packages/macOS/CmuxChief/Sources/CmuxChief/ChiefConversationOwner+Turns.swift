public import CmuxHomeCore
import Foundation

// Chief turns: the queue, the brain stream, drafts, work parts and stop.
extension ChiefConversationOwner {
    /// Stops the running turn of `conversation`.
    ///
    /// The turn ends for Home at once: the text so far commits, running work
    /// turns failed and typing goes off. Then the brain is interrupted
    /// (``ChiefBrain/interrupt(conversation:)``) and the consuming task is
    /// cancelled, which terminates the brain's stream. Queued messages run
    /// after that, never before the interrupt.
    ///
    /// - Parameter conversation: The conversation whose turn stops.
    /// - Returns: True when a turn was running.
    @discardableResult
    public func stopTurn(conversation: ConversationID) async -> Bool {
        guard let turn = running[conversation] else { return false }
        stopping.insert(conversation)
        finishTurn(conversation, failure: nil, stopped: true, startNext: false)
        postStoppedNotice(in: conversation, author: turn.chief, threadRoot: turn.threadRoot) // ChiefConversationOwner+Notices.swift
        await brain.interrupt(conversation: conversation)
        turn.task?.cancel()
        stopping.remove(conversation)
        startNextTurnIfIdle(conversation)
        return true
    }

    func enqueue(_ turn: ChiefPendingTurn, in conversation: ConversationID) {
        pending[conversation, default: []].append(turn)
        startNextTurnIfIdle(conversation)
    }

    func startNextTurnIfIdle(_ conversation: ConversationID) {
        guard running[conversation] == nil, !stopping.contains(conversation), var queue = pending[conversation], !queue.isEmpty else {
            cancelReadCursorRetry(for: conversation)
            return
        }
        guard let state = conversations[conversation], let chief = state.chief else {
            cancelReadCursorRetry(for: conversation)
            return
        }
        // The user's "Always Allow" rules belong to this owner/home.
        allowRules.load(home)
        // A turn must not begin until its read cursor is durably advanced. Keep
        // the queued turn intact when the cursor write fails so a later retry
        // can preserve the same ordering and unread state.
        if let seq = queue[0].readSeq {
            do {
                _ = try moveReadCursor(conversation, of: chief.id, to: seq)
            } catch {
                scheduleReadCursorRetry(for: conversation)
                return
            }
        }
        cancelReadCursorRetry(for: conversation)
        let next = queue.removeFirst()
        pending[conversation] = queue.isEmpty ? nil : queue
        running[conversation] = ChiefRunningTurn(chief: chief.id, threadRoot: next.threadRoot, startedAt: now())
        guard let turnID = running[conversation]?.id else { return }
        publish(.typing(conversation, chief.id, on: true))
        notifyWorking()
        let input = ChiefTurnContextInput(conversation: conversation, chief: chief, home: home, resumeSession: state.cliSession)
        // Runs on this actor; it cannot start before the assignment below.
        running[conversation]?.task = Task { await self.runTurn(turnID, in: conversation, next, input: input) }
    }

    private func scheduleReadCursorRetry(for conversation: ConversationID) {
        guard readCursorRetryTasks[conversation] == nil else { return }
        let clock = self.clock
        readCursorRetryTasks[conversation] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                await self.retryReadCursor(for: conversation)
                if await self.hasReadCursorRetry(for: conversation) == false { return }
            }
        }
    }

    private func retryReadCursor(for conversation: ConversationID) {
        startNextTurnIfIdle(conversation)
    }

    private func hasReadCursorRetry(for conversation: ConversationID) -> Bool {
        readCursorRetryTasks[conversation] != nil
            && pending[conversation]?.isEmpty == false
            && running[conversation] == nil
            && !stopping.contains(conversation)
    }

    private func cancelReadCursorRetry(for conversation: ConversationID) {
        readCursorRetryTasks.removeValue(forKey: conversation)?.cancel()
    }

    func isCurrent(_ turnID: UUID, _ conversation: ConversationID) -> Bool {
        running[conversation]?.id == turnID
    }

    private func runTurn(_ turnID: UUID, in conversation: ConversationID, _ turn: ChiefPendingTurn,
                         input: ChiefTurnContextInput) async {
        let context = await contextProvider(input)
        guard isCurrent(turnID, conversation), !Task.isCancelled else { return }
        running[conversation]?.engine = context.engine
        let request = ChiefTurnRequest(conversation: conversation, resumeSession: input.resumeSession,
                                       userText: context.userText(turn.text), // memory updates since the session began
                                       attachmentPaths: turn.attachmentPaths, replyContext: turn.replyContext,
                                       systemPrompt: context.systemPrompt, workingDirectory: context.workingDirectory,
                                       environment: context.environment)
        var failure: String?
        do {
            stream: for try await event in brain.run(request) {
                guard isCurrent(turnID, conversation) else { return }
                switch event {
                case .finished:
                    break stream
                case .failed(let message):
                    failure = message
                    break stream
                default:
                    apply(event, in: conversation)
                }
            }
        } catch {
            if !(error is CancellationError) { failure = String(describing: error) }
        }
        // A stopped turn was finished by `stopTurn`.
        guard isCurrent(turnID, conversation), !Task.isCancelled else { return }
        finishTurn(conversation, failure: failure, stopped: false)
    }

    private func apply(_ event: ChiefTurnEvent, in conversation: ConversationID) {
        guard var turn = running[conversation] else { return }
        switch event {
        case .session(let session):
            guard var state = conversations[conversation], state.cliSession != session else { return }
            state.cliSession = session
            do {
                try persist(conversation, [.session(session)])
            } catch {
                return
            }
            conversations[conversation] = state
        case .textDelta(let text):
            guard !text.isEmpty else { return }
            let fresh = turn.segmentKey == nil
            let key = turn.segmentKey ?? .make()
            turn.segmentKey = key
            turn.segmentText += text
            turn.draftSeq += 1
            // A new key starts a new draft turn, whose first item must be fresh.
            publish(.draft(HomeDraftUpdate(conversation: conversation, participant: turn.chief, turn: key, segment: turn.segment,
                                           seq: turn.draftSeq, isTalk: true, text: fresh ? turn.segmentText : text,
                                           fresh: fresh, done: false)))
            running[conversation] = turn
        case .textSegmentEnd:
            flushSegment(&turn, in: conversation, retype: true)
            running[conversation] = turn
        case .toolStarted(let id, let title, let detail):
            flushSegment(&turn, in: conversation, retype: false)
            turn.toolCalls += 1
            if let phase = ChiefCloudProvisioning.phase(ofCommand: detail ?? title) {
                startProvisioning(id, phase: phase, command: detail ?? title, turn: &turn, in: conversation)
                running[conversation] = turn
                return
            }
            let work = WorkRef(session: id, title: title, status: .running, preview: detail)
            // No typing dots while a work row runs: its spinner is the live indicator.
            if let message = postChief([.work(work)], in: conversation, turn: turn, key: .make(), retype: false) {
                turn.tools[id] = message.id
            }
            running[conversation] = turn
            publish(.typing(conversation, turn.chief, on: false))
        case .toolFinished(let id, let ok, let preview):
            guard let messageID = turn.tools.removeValue(forKey: id) else { return }
            if !ok { turn.failedToolCalls += 1 }
            running[conversation] = turn
            if let phase = turn.provisioningCalls.removeValue(forKey: id) {
                finishProvisioning(messageID, phase: phase, ok: ok, output: preview, turn: &turn, in: conversation)
                running[conversation] = turn
                retypeAfterWork(turn, in: conversation)
                return
            }
            setWorkStatus(messageID, in: conversation, ok ? .done : .failed, preview: preview)
            retypeAfterWork(turn, in: conversation)
        case .question(let question):
            flushSegment(&turn, in: conversation, retype: false)
            postChief([.question(question)], in: conversation, turn: turn, key: .make(), retype: true)
            running[conversation] = turn
        case .approvalRequested(let id, let prompt, let options):
            flushSegment(&turn, in: conversation, retype: false)
            let ref = ApprovalRef(request: turn.cardRequestID(id), prompt: prompt, options: options)
            // The card takes the place of the tool's own running row, so the command shows once.
            // A `vm new`'s card takes its provisioning row's place too (ChiefConversationOwner+Provisioning.swift).
            if let work = workAwaitingApproval(prompt, turn: turn, in: conversation)
                ?? provisioningAwaitingApproval(prompt, turn: turn, in: conversation),
               (try? updateMessage(work.message, in: conversation, { $0.parts = [.approval(ref)] })) != nil {
                let slot = ChiefApprovalSlot(message: work.message, part: 0)
                turn.tools[work.tool] = nil
                turn.approvals[slot] = id
                turn.approvedWork[slot] = (work.tool, work.work)
            } else if let message = postChief([.approval(ref)], in: conversation, turn: turn, key: .make(), retype: false) {
                turn.approvals[ChiefApprovalSlot(message: message.id, part: 0)] = id
            }
            running[conversation] = turn
            // The Chief waits for the user now: no typing dots under the card.
            publish(.typing(conversation, turn.chief, on: false))
            notifyWorking()
        case .result(let card):
            flushSegment(&turn, in: conversation, retype: false)
            postChief([.work(Self.resultWork(card))], in: conversation, turn: turn, key: .make(), retype: true)
            running[conversation] = turn
        case .usage(let usage):
            turn.usage = usage
            running[conversation] = turn
        case .finished, .failed:
            break
        }
    }

    // MARK: Cloud provisioning

    /// Maps a provisioning call onto the turn's one provisioning row: the
    /// first call posts it, later ones (`vm wait` after `vm new`, a retry)
    /// set it running again.
    private func startProvisioning(_ id: String, phase: ChiefCloudProvisioning, command: String,
                                   turn: inout ChiefRunningTurn, in conversation: ConversationID) {
        let machine = phase == .wait ? ChiefCloudProvisioning.machine(inCommand: command) : nil
        // The row shows the machine's name ("chief-dogfood-1"), its id stays in `host` (the tooltip).
        let name = Self.machineName(inCommand: command)
        turn.provisioningCalls[id] = phase
        turn.provisioningStatus = .running
        if let row = turn.provisioning {
            turn.tools[id] = row
            updateWork(row, in: conversation) { work in
                work.status = .running
                if let machine { work.host = machine }
                if let name { work.preview = name }
            }
            // The row runs again (an update, not a post): its spinner is the one live indicator.
            publish(.typing(conversation, turn.chief, on: false))
            return
        }
        let work = WorkRef(session: ChiefCloudProvisioning.sessionPrefix + UUID().uuidString.lowercased(), host: machine,
                           title: ChiefCloudProvisioning.title, status: .running, preview: name)
        if let message = postChief([.work(work)], in: conversation, turn: turn, key: .make(), retype: false) {
            turn.provisioning = message.id
            turn.tools[id] = message.id
        }
    }

    /// A provisioning call ended: `vm new` leaves the row creating (the wait
    /// follows) and records the machine; `vm wait` makes it ready; a failure fails it.
    private func finishProvisioning(_ row: MessageID, phase: ChiefCloudProvisioning, ok: Bool, output: String?,
                                    turn: inout ChiefRunningTurn, in conversation: ConversationID) {
        let status: WorkRef.Status = !ok ? .failed : phase == .wait ? .done : .running
        turn.provisioningStatus = status
        let machine = ChiefCloudProvisioning.machine(inOutput: output)
        let name = ok ? Self.machineName(inOutput: output) : nil
        updateWork(row, in: conversation) { work in
            work.status = status
            if let machine { work.host = machine }
            if let name { work.preview = name }
            // Keep the human-readable machine name after a later wait fails.
            // The failure state already tells Home to draw the red result; the
            // raw command output belongs in the tool log, not in the machine
            // label users act on.
            if !ok, work.preview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                work.preview = output
            }
        }
    }

    private func updateWork(_ messageID: MessageID, in conversation: ConversationID, _ change: (inout WorkRef) -> Void) {
        _ = try? updateMessage(messageID, in: conversation) { message in
            message.parts = message.parts.map { part in
                guard case .work(var work) = part else { return part }
                change(&work)
                return .work(work)
            }
        }
    }

    /// A provisioning row's machine name: `--name <name>` on the command, or `"name"` in
    /// `vm new --json` output. The row stores it as its preview while it has not failed (a
    /// failure's preview is the output).
    static func machineName(inCommand command: String) -> String? { ChiefCloudProvisioning.machineName(inCommand: command) }

    /// `vm new --json` answers `"displayName"` (``ChiefCloudProvisioning/machineName(inOutput:)``).
    static func machineName(inOutput output: String?) -> String? { ChiefCloudProvisioning.machineName(inOutput: output) }

    /// The stored part of a result card: a work part whose `host` is the
    /// machine and whose `session` is the machine workspace (`ws_…`).
    static func resultWork(_ card: ChiefResultCard) -> WorkRef {
        let status: WorkRef.Status
        switch card.status {
        case .working: status = .running
        case .ready: status = .done
        case .failed: status = .failed
        // Home draws a waiting card with the attention colour ("Needs sign-in").
        case .needsSignIn: status = .waiting
        }
        return WorkRef(session: card.workspace, host: card.machine, title: card.title, status: status, preview: card.subtitle)
    }

    /// Commits the current text segment as one Chief message (its client id
    /// is the draft's turn key, so the draft ends with it) and starts the next.
    private func flushSegment(_ turn: inout ChiefRunningTurn, in conversation: ConversationID, retype: Bool) {
        guard let key = turn.segmentKey else { return }
        let text = turn.segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            turn.draftSeq += 1
            publish(.draft(HomeDraftUpdate(conversation: conversation, participant: turn.chief, turn: key, segment: turn.segment,
                                           seq: turn.draftSeq, isTalk: true, text: "", fresh: false, done: true)))
        } else {
            postChief([.text(text)], in: conversation, turn: turn, key: key, retype: retype)
        }
        turn.segmentKey = nil
        turn.segmentText = ""
        turn.segment += 1
    }

    /// Posts a Chief message in the turn's thread. A post ends the author's
    /// typing on clients, so a turn that goes on turns typing back on.
    @discardableResult
    private func postChief(_ parts: [MessagePart], in conversation: ConversationID, turn: ChiefRunningTurn,
                           key: IdempotencyKey, retype: Bool) -> Message? {
        let message = try? commitMessage(in: conversation, author: turn.chief, parts: parts, key: key, threadRoot: turn.threadRoot)
        // Never while a work row of the turn runs or a card waits: one live indicator at a time.
        if retype, message != nil, turn.tools.isEmpty, turn.approvals.isEmpty { publish(.typing(conversation, turn.chief, on: true)) }
        return message
    }

    /// The Chief types again once no work row of the turn runs and no card waits (between a finished
    /// tool and its next words): one live indicator at a time.
    private func retypeAfterWork(_ turn: ChiefRunningTurn, in conversation: ConversationID) {
        guard turn.tools.isEmpty, turn.approvals.isEmpty else { return }
        publish(.typing(conversation, turn.chief, on: true))
    }

    private func setWorkStatus(_ messageID: MessageID, in conversation: ConversationID, _ status: WorkRef.Status, preview: String?) {
        _ = try? updateMessage(messageID, in: conversation) { message in
            message.parts = message.parts.map { part in
                guard case .work(var work) = part else { return part }
                work.status = status
                if let preview { work.preview = preview }
                return .work(work)
            }
        }
    }

    /// Ends the running turn: commits the text so far, settles running work,
    /// posts a failure, turns typing off and starts the next queued turn.
    func finishTurn(_ conversation: ConversationID, failure: String?, stopped: Bool, startNext: Bool = true) {
        guard var turn = running[conversation] else { return }
        flushSegment(&turn, in: conversation, retype: false)
        let status: WorkRef.Status = failure == nil && !stopped ? .done : .failed
        for messageID in Set(turn.tools.values) { setWorkStatus(messageID, in: conversation, status, preview: nil) }
        // A card still waiting when the turn ends (Stop, a failure) was refused: the brain denies open approvals.
        for slot in turn.approvals.keys { settleApproval(slot, in: conversation) }
        // A provisioning row whose calls all ended keeps its own outcome; one still creating settles with the turn.
        if let row = turn.provisioning, turn.provisioningStatus == .running, !turn.tools.values.contains(row) {
            setWorkStatus(row, in: conversation, status, preview: nil)
        }
        if let failure {
            // A system row, not a Chief bubble (Home draws it with Try Again): a work part under the failure prefix.
            let work = WorkRef(session: Self.failureSessionPrefix + UUID().uuidString.lowercased(), title: Self.failureText(failure),
                               status: .failed, preview: nil)
            postChief([.work(work)], in: conversation, turn: turn, key: .make(), retype: false)
        }
        // The notes saved during the turn, after its last message.
        for note in turn.memoryNotes { postMemoryNote(note.fact, text: note.text, duringTurn: true, in: conversation, author: turn.chief) }
        running[conversation] = nil
        let ended = now()
        lastTurns[conversation] = ChiefTurnStats(
            engine: turn.engine, duration: max(0, ended.timeIntervalSince(turn.startedAt)), toolCalls: turn.toolCalls,
            failedToolCalls: turn.failedToolCalls, cacheHitRate: turn.usage?.cacheHitRate, failed: failure != nil,
            stopped: stopped, endedAt: ended)
        publish(.typing(conversation, turn.chief, on: false))
        notifyWorking()
        if startNext { startNextTurnIfIdle(conversation) }
    }

    /// Answers an approval card: the approval part records the choice, then
    /// the brain hears it under its own request id
    /// (``ChiefBrain/respond(toApproval:choice:conversation:)``).
    ///
    /// A card is addressed by its place (message and part), never by request
    /// id alone: brains reuse request ids across processes.
    ///
    /// - Parameters:
    ///   - conversation: The conversation of the approval message.
    ///   - message: The approval's message.
    ///   - part: The approval part's index in that message.
    ///   - choice: One of the approval's options.
    /// - Throws: ``HomeRejection/invalid(_:)``: `unknown_approval` when that part is
    ///   no approval, `approval_decided` when it was answered or its turn ended
    ///   (an earlier turn's card is marked expired), `invalid_choice` when the
    ///   choice is not an option.
    public func answerApproval(conversation: ConversationID, message: MessageID, part: Int, choice: String) async throws {
        let request = try decideApproval(conversation: conversation, slot: ChiefApprovalSlot(message: message, part: part),
                                         choice: choice)
        await brain.respond(toApproval: request, choice: choice, conversation: conversation)
    }

    /// Records `choice` on the approval part; the Chief types again once no card of its turn waits.
    /// The caller tells the brain.
    ///
    /// - Returns: The brain's own request id of the card.
    func decideApproval(conversation: ConversationID, slot: ChiefApprovalSlot, choice: String) throws -> String {
        let state = try conversationState(conversation)
        guard let message = state.message(slot.message), message.parts.indices.contains(slot.part),
              case .approval(let ref) = message.parts[slot.part] else { throw HomeRejection.invalid("unknown_approval") }
        guard ref.decided == nil else { throw HomeRejection.invalid("approval_decided") }
        // The rule-carrying option is the card's menu, never an answer.
        guard ref.options.contains(choice), !ChiefAllowRules.isAlwaysOption(choice) else {
            throw HomeRejection.invalid("invalid_choice")
        }
        guard var turn = running[conversation], let request = turn.approvals[slot] else {
            // No running turn waits on this card (it is an earlier turn's): nobody can answer it any more.
            setApprovalDecision(slot, in: conversation, Self.approvalExpired)
            throw HomeRejection.invalid("approval_decided")
        }
        turn.approvals[slot] = nil
        let replaced = turn.approvedWork.removeValue(forKey: slot)
        setApprovalDecision(slot, in: conversation, choice)
        // Allowed: the tool's running row comes back right under the receipt (Home folds the two into
        // "Ran … · Allowed"), and its finish settles it. Its spinner is the live indicator: no typing dots.
        if let replaced, !ChiefToolPolicy.isRefusal(choice),
           let row = postChief([.work(replaced.work)], in: conversation, turn: turn, key: .make(), retype: false) {
            turn.tools[replaced.tool] = row.id
        }
        if let replaced { Self.resumeProvisioning(after: replaced.work, tool: replaced.tool, turn: &turn) }
        running[conversation] = turn
        if turn.approvals.isEmpty, turn.tools.isEmpty { publish(.typing(conversation, turn.chief, on: true)) }
        notifyWorking()
        return request
    }

    /// An approval card `chief.approve` can answer (``pendingApproval(in:request:)``).
    public struct PendingApproval: Sendable, Equatable {
        /// The card's message.
        public var message: MessageID
        /// The approval part's index in that message.
        public var part: Int
        /// The approval.
        public var ref: ApprovalRef
        /// The card's request id (``ApprovalRef/request``).
        public var request: String { ref.request }
    }

    /// The approval card `chief.approve` answers in `conversation`.
    ///
    /// - Parameters:
    ///   - conversation: The conversation.
    ///   - request: Only the newest card with this request id (``ApprovalRef/request``), decided or
    ///     not; nil: the newest card of the running turn that still waits (never an earlier turn's).
    /// - Returns: The card, nil when none matches.
    public func pendingApproval(in conversation: ConversationID, request: String? = nil) -> PendingApproval? {
        guard let state = conversations[conversation] else { return nil }
        guard let request else {
            guard let turn = running[conversation] else { return nil }
            var best: (card: PendingApproval, seq: Seq)?
            for slot in turn.approvals.keys {
                guard let message = state.message(slot.message), message.parts.indices.contains(slot.part),
                      case .approval(let ref) = message.parts[slot.part], ref.decided == nil else { continue }
                if best.map({ message.seq > $0.seq || (message.seq == $0.seq && slot.part > $0.card.part) }) ?? true {
                    best = (PendingApproval(message: slot.message, part: slot.part, ref: ref), message.seq)
                }
            }
            return best?.card
        }
        for message in state.messages.reversed() {
            for (index, part) in message.parts.enumerated().reversed() {
                if case .approval(let ref) = part, ref.request == request {
                    return PendingApproval(message: message.id, part: index, ref: ref)
                }
            }
        }
        return nil
    }

    /// Whether an approval card of `conversation`'s running turn waits for the user.
    public func isWaitingForApproval(_ conversation: ConversationID) -> Bool {
        running[conversation].map { !$0.approvals.isEmpty } ?? false
    }

    /// The running tool whose call `prompt` asks about: its command or title is in the prompt
    /// (ChiefToolPolicy.claudePrompt quotes the command), the newest such call.
    private func workAwaitingApproval(_ prompt: String, turn: ChiefRunningTurn,
                                      in conversation: ConversationID) -> (tool: String, message: MessageID, work: WorkRef)? {
        guard let state = conversations[conversation] else { return nil }
        var best: (tool: String, message: MessageID, work: WorkRef, seq: Seq)?
        for (tool, messageID) in turn.tools where messageID != turn.provisioning {
            guard let message = state.message(messageID), message.parts.count == 1 else { continue }
            for case .work(let work) in message.parts where work.status == .running && work.host == nil {
                let needles = [work.preview, work.title].compactMap { $0 }.map { String($0.prefix(200)) }.filter { !$0.isEmpty }
                guard needles.contains(where: { prompt.contains($0) }) else { continue }
                if best.map({ message.seq > $0.seq }) ?? true { best = (tool, messageID, work, message.seq) }
            }
        }
        return best.map { ($0.tool, $0.message, $0.work) }
    }

    /// Marks a card no answer reached as refused (its turn ended).
    private func settleApproval(_ slot: ChiefApprovalSlot, in conversation: ConversationID) {
        guard let message = conversations[conversation]?.message(slot.message), message.parts.indices.contains(slot.part),
              case .approval(let ref) = message.parts[slot.part], ref.decided == nil else { return }
        setApprovalDecision(slot, in: conversation, ref.options.first(where: ChiefToolPolicy.isRefusal) ?? "Deny")
    }

    /// Records `decision` on an undecided approval part.
    private func setApprovalDecision(_ slot: ChiefApprovalSlot, in conversation: ConversationID, _ decision: String) {
        _ = try? updateMessage(slot.message, in: conversation) { message in
            guard message.parts.indices.contains(slot.part), case .approval(var ref) = message.parts[slot.part],
                  ref.decided == nil else { return }
            ref.decided = decision
            message.parts[slot.part] = .approval(ref)
        }
    }

    /// The stats of `conversation`'s last finished turn (this session), nil before one ends.
    ///
    /// - Parameter conversation: The conversation.
    /// - Returns: Its last turn's engine, duration, tool calls and cache share.
    public func lastTurnStats(in conversation: ConversationID) -> ChiefTurnStats? {
        lastTurns[conversation]
    }

    /// The text of the system row a failed turn posts.
    static func failureText(_ error: String) -> String {
        ChiefText.turnFailed(error)
    }

    /// The session prefix of a failed turn's work part (Home's `ChiefRows.failurePrefix`, the same id;
    /// change both). Home draws it as an error row with Try Again, never as a tool call.
    public static let failureSessionPrefix = "chief.failure:"
}
