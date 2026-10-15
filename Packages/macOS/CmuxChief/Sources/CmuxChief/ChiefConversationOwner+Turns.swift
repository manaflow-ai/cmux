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
        guard running[conversation] == nil, !stopping.contains(conversation), var queue = pending[conversation], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        pending[conversation] = queue.isEmpty ? nil : queue
        guard let state = conversations[conversation], let chief = state.chief else { return }
        if let seq = next.readSeq { moveReadCursor(conversation, of: chief.id, to: seq) }
        running[conversation] = ChiefRunningTurn(chief: chief.id, threadRoot: next.threadRoot, startedAt: now())
        guard let turnID = running[conversation]?.id else { return }
        publish(.typing(conversation, chief.id, on: true))
        notifyWorking()
        let input = ChiefTurnContextInput(conversation: conversation, chief: chief, home: home, resumeSession: state.cliSession)
        // Runs on this actor; it cannot start before the assignment below.
        running[conversation]?.task = Task { await self.runTurn(turnID, in: conversation, next, input: input) }
    }

    func isCurrent(_ turnID: UUID, _ conversation: ConversationID) -> Bool {
        running[conversation]?.id == turnID
    }

    private func runTurn(_ turnID: UUID, in conversation: ConversationID, _ turn: ChiefPendingTurn,
                         input: ChiefTurnContextInput) async {
        let context = await contextProvider(input)
        guard isCurrent(turnID, conversation), !Task.isCancelled else { return }
        running[conversation]?.engine = context.engine
        let request = ChiefTurnRequest(conversation: conversation, resumeSession: input.resumeSession, userText: turn.text,
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
            conversations[conversation] = state
            persist(conversation, [.session(session)])
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
            if let message = postChief([.work(work)], in: conversation, turn: turn, key: .make(), retype: true) {
                turn.tools[id] = message.id
            }
            running[conversation] = turn
        case .toolFinished(let id, let ok, let preview):
            guard let messageID = turn.tools.removeValue(forKey: id) else { return }
            if !ok { turn.failedToolCalls += 1 }
            running[conversation] = turn
            if let phase = turn.provisioningCalls.removeValue(forKey: id) {
                finishProvisioning(messageID, phase: phase, ok: ok, output: preview, turn: &turn, in: conversation)
                running[conversation] = turn
                return
            }
            setWorkStatus(messageID, in: conversation, ok ? .done : .failed, preview: preview)
        case .question(let question):
            flushSegment(&turn, in: conversation, retype: false)
            postChief([.question(question)], in: conversation, turn: turn, key: .make(), retype: true)
            running[conversation] = turn
        case .approvalRequested(let id, let prompt, let options):
            flushSegment(&turn, in: conversation, retype: false)
            postChief([.approval(ApprovalRef(request: id, prompt: prompt, options: options))], in: conversation, turn: turn,
                      key: .make(), retype: true)
            running[conversation] = turn
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
    private func startProvisioning(_ id: String, phase: ChiefCloudProvisioning.Phase, command: String,
                                   turn: inout ChiefRunningTurn, in conversation: ConversationID) {
        let machine = phase == .wait ? ChiefCloudProvisioning.machine(inCommand: command) : nil
        turn.provisioningCalls[id] = phase
        turn.provisioningStatus = .running
        if let row = turn.provisioning {
            turn.tools[id] = row
            updateWork(row, in: conversation) { work in
                work.status = .running
                if let machine { work.host = machine }
            }
            return
        }
        let work = WorkRef(session: ChiefCloudProvisioning.sessionPrefix + UUID().uuidString.lowercased(), host: machine,
                           title: ChiefCloudProvisioning.title, status: .running, preview: nil)
        if let message = postChief([.work(work)], in: conversation, turn: turn, key: .make(), retype: true) {
            turn.provisioning = message.id
            turn.tools[id] = message.id
        }
    }

    /// A provisioning call ended: `vm new` leaves the row creating (the wait
    /// follows) and records the machine; `vm wait` makes it ready; a failure fails it.
    private func finishProvisioning(_ row: MessageID, phase: ChiefCloudProvisioning.Phase, ok: Bool, output: String?,
                                    turn: inout ChiefRunningTurn, in conversation: ConversationID) {
        let status: WorkRef.Status = !ok ? .failed : phase == .wait ? .done : .running
        turn.provisioningStatus = status
        let machine = ChiefCloudProvisioning.machine(inOutput: output)
        updateWork(row, in: conversation) { work in
            work.status = status
            if let machine { work.host = machine }
            if !ok { work.preview = output }
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

    /// The stored part of a result card: a work part whose `host` is the
    /// machine and whose `session` is the machine workspace (`ws_…`).
    static func resultWork(_ card: ChiefResultCard) -> WorkRef {
        let status: WorkRef.Status
        switch card.status {
        case .working: status = .running
        case .ready: status = .done
        case .failed: status = .failed
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
        if retype, message != nil { publish(.typing(conversation, turn.chief, on: true)) }
        return message
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
        // A provisioning row whose calls all ended keeps its own outcome; one still creating settles with the turn.
        if let row = turn.provisioning, turn.provisioningStatus == .running, !turn.tools.values.contains(row) {
            setWorkStatus(row, in: conversation, status, preview: nil)
        }
        if let failure {
            postChief([.text(Self.failureText(failure))], in: conversation, turn: turn, key: .make(), retype: false)
        }
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

    /// Answers an approval the Chief asked for: the approval part records
    /// the choice, then the brain hears it
    /// (``ChiefBrain/respond(toApproval:choice:conversation:)``).
    ///
    /// - Parameters:
    ///   - conversation: The conversation of the approval message.
    ///   - request: The approval's id (``ApprovalRef/request``).
    ///   - choice: One of the approval's options.
    /// - Throws: ``HomeRejection/invalid(_:)`` when no open approval has that
    ///   id (`unknown_approval`, `approval_decided`) or the choice is not an option.
    public func answerApproval(conversation: ConversationID, request: String, choice: String) async throws {
        let state = try conversationState(conversation)
        var match: (message: MessageID, part: Int, ref: ApprovalRef)?
        search: for message in state.messages.reversed() {
            for (index, part) in message.parts.enumerated() {
                if case .approval(let ref) = part, ref.request == request {
                    match = (message.id, index, ref)
                    break search
                }
            }
        }
        guard let found = match else { throw HomeRejection.invalid("unknown_approval") }
        guard found.ref.decided == nil else { throw HomeRejection.invalid("approval_decided") }
        guard found.ref.options.contains(choice) else { throw HomeRejection.invalid("invalid_choice") }
        try updateMessage(found.message, in: conversation) { message in
            var ref = found.ref
            ref.decided = choice
            message.parts[found.part] = .approval(ref)
        }
        await brain.respond(toApproval: request, choice: choice, conversation: conversation)
    }

    /// The stats of `conversation`'s last finished turn (this session), nil before one ends.
    ///
    /// - Parameter conversation: The conversation.
    /// - Returns: Its last turn's engine, duration, tool calls and cache share.
    public func lastTurnStats(in conversation: ConversationID) -> ChiefTurnStats? {
        lastTurns[conversation]
    }

    /// The text of the Chief message a failed turn posts.
    static func failureText(_ error: String) -> String {
        "Chief could not finish this reply: \(error)\nSend your message again to retry."
    }
}
