import CmuxConversationCore
import CmuxMobileShell
import Foundation

/// ConversationBackend adapter for the Mac-owned Chief transcript.
///
/// Chief exposes an event-backed read wait rather than a mobile event topic.
/// The adapter waits for the owner's next change while the conversation is
/// visible, then refreshes its newest page so the generic Messages UI remains
/// live without a fixed polling cadence.
final class ChiefConversationBackend: ConversationBackend, @unchecked Sendable {
    private static let deselectUnsupported = String(localized: "mobile.chief.error.deselectUnsupported", defaultValue: "Chief cards cannot be deselected", bundle: .module)
    private static let openQuestionSheet = String(localized: "mobile.chief.error.openQuestionSheet", defaultValue: "Open the Chief question sheet to answer this card", bundle: .module)
    private static let cardAlreadyAnswered = String(localized: "mobile.chief.error.cardAlreadyAnswered", defaultValue: "That Chief card is already being answered", bundle: .module)
    private static let approvalAlreadyAnswered = String(localized: "mobile.chief.error.approvalAlreadyAnswered", defaultValue: "That approval was already answered", bundle: .module)
    private static let questionAlreadyAnswered = String(localized: "mobile.chief.error.questionAlreadyAnswered", defaultValue: "That question was already answered", bundle: .module)
    private static let optionUnavailable = String(localized: "mobile.chief.error.optionUnavailable", defaultValue: "That question option is no longer available", bundle: .module)
    private static let answeredCardMissing = String(localized: "mobile.chief.error.answeredCardMissing", defaultValue: "Chief did not return the answered card", bundle: .module)
    private static let questionNotWaiting = String(localized: "mobile.chief.error.questionNotWaiting", defaultValue: "That Chief question is no longer waiting", bundle: .module)
    private static let answerRequired = String(localized: "mobile.chief.error.answerRequired", defaultValue: "Choose an answer before submitting", bundle: .module)
    private static let answeredQuestionMissing = String(localized: "mobile.chief.error.answeredQuestionMissing", defaultValue: "Chief did not return the answered question", bundle: .module)

    private static func unsupportedBackendText(_ operation: String) -> String {
        String(
            format: String(localized: "mobile.chief.error.unsupported", defaultValue: "Chief does not support %@", bundle: .module),
            operation
        )
    }

    /// Synthetic poll option used to open the full multi-question composer.
    static let questionComposerOptionID = "__chief_answer_questions__"
    private let client: MobileChiefClient
    private let conversationID: String
    private let fallbackTitle: String
    private let clock: any Clock<Duration>
    // Concurrency carve-out: ConversationBackend exposes synchronous lifecycle
    // methods while its polling task is asynchronous, so state needs one small
    // critical section instead of an actor hop from every callback.
    private let stateLock = NSLock()
    private var state = State()

    private struct State {
        static let cachedMessageLimit = 2_048
        var previousMessagesByID: [String: MobileChiefMessage] = [:]
        /// Structured Chief cards are kept as backend metadata while the
        /// generic conversation model renders pending cards as polls.
        var structuredPartsByMessageID: [String: [MobileChiefPart]] = [:]
        var decidingMessageIDs: Set<String> = []
        var pendingSends: [String: PendingSend] = [:]
        /// A poll/history pass may correlate the committed echo while the
        /// send request is still waiting for its follow-up read. Keep that
        /// echo for `send` so its fallback cannot return a second local row.
        var correlatedMessagesByClientID: [String: MobileChiefMessage] = [:]
        // ChiefConversationOwner's canonical signed-in participant id.
        // Keep own-message styling correct even when the newest page contains
        // only Chief/tool output and therefore has no human row to infer it
        // from.
        var meID = "me"
        var publishedMeID: String?
        var eventSeq = 0
        var pollTask: Task<Void, Never>?
        var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
        var closed = false
    }

    private struct PendingSend {
        let clientMessageID: String
        let text: String
        let startedAt: Date
        var serverMessageID: String?
    }

    private struct EventResources {
        let pollTask: Task<Void, Never>?
        let continuation: AsyncStream<ConversationBackendEvent>.Continuation?
    }

    init(
        client: MobileChiefClient,
        conversationID: String,
        title: String,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.client = client
        self.conversationID = conversationID
        self.fallbackTitle = title
        self.clock = clock
    }

    func events() -> AsyncStream<ConversationBackendEvent> {
        let streamAndContinuation: (
            stream: AsyncStream<ConversationBackendEvent>,
            continuation: AsyncStream<ConversationBackendEvent>.Continuation
        ) = AsyncStream<ConversationBackendEvent>.makeStream()
        let stream = streamAndContinuation.stream
        let continuation = streamAndContinuation.continuation
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.poll(continuation: continuation)
        }
        let previous: EventResources = withState { state in
            guard !state.closed else {
                continuation.finish()
                return EventResources(pollTask: task, continuation: nil)
            }
            let previous = EventResources(pollTask: state.pollTask, continuation: state.continuation)
            state.continuation = continuation
            state.pollTask = task
            return previous
        }
        previous.pollTask?.cancel()
        previous.continuation?.finish()
        return stream
    }

    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        let before = beforeSeq.flatMap { $0 > 0 ? UInt64($0) : nil }
        let result = try await client.read(conversation: conversationID, beforeSeq: before, limit: limit)
        let mapped = result.messages.map {
            map($0, clientMessageID: clientMessageID(for: $0))
        }
        withState { state in
            mergeMessages(result.messages, into: &state)
        }
        return ConversationHistoryPage(messages: mapped, hasMore: result.hasMore)
    }

    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        let startedAt = Date()
        withState { state in
            state.pendingSends[draft.clientMessageID] = PendingSend(
                clientMessageID: draft.clientMessageID,
                text: draft.text,
                startedAt: startedAt,
                serverMessageID: nil
            )
        }
        let sendResult: MobileChiefSendResult
        do {
            sendResult = try await client.send(
                draft.text,
                conversation: conversationID,
                clientMessageID: draft.clientMessageID
            )
        } catch {
            withState { $0.pendingSends.removeValue(forKey: draft.clientMessageID) }
            throw error
        }
        withState { state in
            state.pendingSends[draft.clientMessageID]?.serverMessageID = sendResult.messageID
        }
        do {
            let result = try await client.read(conversation: conversationID, limit: 200)
            let exactClientMessageIDs = Set(
                [draft.clientMessageID, sendResult.clientMessageID].compactMap { $0 }
            )
            let sent = result.messages.first { message in
                guard let clientMessageID = message.clientMessageID else { return false }
                return exactClientMessageIDs.contains(clientMessageID)
            } ?? sendResult.messageID.flatMap { messageID in
                result.messages.first { $0.id == messageID }
            } ?? result.messages
                .filter {
                    $0.authorKind == "human"
                        && $0.text == draft.text
                        && $0.at >= startedAt.addingTimeInterval(-5)
                }
                .max(by: { $0.at < $1.at })
            if let sent {
                _ = takeCorrelatedMessage(for: draft.clientMessageID)
                withState { $0.pendingSends.removeValue(forKey: draft.clientMessageID) }
                publishIdentityIfNeeded(for: sent)
                var message = map(sent, clientMessageID: draft.clientMessageID)
                message.clientMessageID = draft.clientMessageID
                message.delivery = sendResult.queued ? .sending : .sent
                return message
            }
        } catch {
            // Chief accepted the send, but its follow-up read may transiently
            // fail. Keep the pending correlation so the poll can merge the
            // committed echo into the optimistic row instead of duplicating it.
        }
        // A concurrent poll/history read may have observed and correlated the
        // committed echo while the send's read was delayed or failed. Return
        // that server row so ConversationStore's idempotent upsert sees the
        // same id instead of appending the local fallback after the echo.
        if let sent = takeCorrelatedMessage(for: draft.clientMessageID) {
            withState { $0.pendingSends.removeValue(forKey: draft.clientMessageID) }
            publishIdentityIfNeeded(for: sent)
            var message = map(sent, clientMessageID: draft.clientMessageID)
            message.clientMessageID = draft.clientMessageID
            message.delivery = sendResult.queued ? .sending : .sent
            return message
        }
        // Some Chief owners acknowledge before the committed message is
        // visible to `chief.read`; preserve the optimistic row identity so a
        // later poll can replace it without duplicating the bubble.
        return ConversationMessage(
            id: "local:\(draft.clientMessageID)",
            seq: nil,
            clientMessageID: draft.clientMessageID,
            senderID: withState { $0.meID },
            sentAt: Date(),
            text: draft.text,
            delivery: sendResult.queued ? .sending : .sent
        )
    }

    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        throw unsupported("reactions")
    }

    /// Chief approvals and questions use the generic conversation poll card
    /// as their compact, tappable representation. A selected poll option is
    /// converted back to the card's Chief RPC; deselecting is not meaningful
    /// once Chief has accepted an answer.
    func votePoll(messageID: String, optionID: String, selected: Bool) async throws -> ConversationMessage {
        guard selected else {
            throw ConversationBackendError(code: -1, message: Self.deselectUnsupported)
        }
        if optionID == Self.questionComposerOptionID {
            throw ConversationBackendError(code: -1, message: Self.openQuestionSheet)
        }
        let pendingPart: MobileChiefPart? = withState { state in
            guard let parts = state.structuredPartsByMessageID[messageID] else { return nil }
            return Self.pendingPollPart(from: parts)
        }
        guard let part = pendingPart else {
            throw unsupported("polls")
        }
        let claimed = withState { state in
            state.decidingMessageIDs.insert(messageID).inserted
        }
        guard claimed else {
            throw ConversationBackendError(code: -1, message: Self.cardAlreadyAnswered)
        }
        defer {
            withState { $0.decidingMessageIDs.remove(messageID) }
        }
        switch part.kind {
        case "approval":
            guard let approval = part.approval else { throw unsupported("approval cards") }
            guard approval.decided == nil else {
                throw ConversationBackendError(code: -1, message: Self.approvalAlreadyAnswered)
            }
            _ = try await client.approve(conversation: conversationID, request: approval.request, choice: optionID)
        case "question":
            guard let question = part.question else {
                throw unsupported("question cards")
            }
            guard question.isPending else {
                throw ConversationBackendError(code: -1, message: Self.questionAlreadyAnswered)
            }
            guard let item = Self.pollQuestion(from: question) else {
                throw unsupported("multi-item or multi-select question cards")
            }
            guard item.options.contains(where: { $0.id == optionID }) else {
                throw ConversationBackendError(code: -1, message: Self.optionUnavailable)
            }
            // The generic poll can represent one single-select item. Do not
            // invent answers for hidden items or collapse a multi-select ask
            // into one selection; those require the complete question form.
            _ = try await client.answer(
                conversation: conversationID,
                message: messageID,
                choices: [optionID],
                text: nil
            )
        default:
            throw unsupported("polls")
        }

        let refreshed: MobileChiefReadResult
        do {
            refreshed = try await client.read(conversation: conversationID, limit: 200)
        } catch {
            if let previous = withState({ $0.previousMessagesByID[messageID] }) {
                return publishUpdatedMessage(previous)
            }
            throw error
        }
        if let message = refreshed.messages.first(where: { $0.id == messageID }) {
            return publishUpdatedMessage(message)
        }
        // A card loaded from an older history page may be outside the newest
        // 200-message tail. Read the page ending at that message so an
        // answered card collapses to the server receipt instead of leaving a
        // stale actionable poll in the store.
        if let previous = withState({ $0.previousMessagesByID[messageID] }),
           previous.seq < UInt64.max,
           let targeted = try? await client.read(
               conversation: conversationID,
               beforeSeq: previous.seq + 1,
               limit: 1
           ),
           let message = targeted.messages.first(where: { $0.id == messageID }) {
            withState { $0.previousMessagesByID[messageID] = message }
            return publishUpdatedMessage(message)
        }
        // The answer RPC commits before the transcript snapshot necessarily
        // includes the changed card. Return the last known row so the store
        // does not show a false vote failure; the next poll will collapse it
        // to the server's receipt.
        if let previous = withState({ $0.previousMessagesByID[messageID] }) {
            return publishUpdatedMessage(previous)
        }
        throw ConversationBackendError(code: -1, message: Self.answeredCardMissing)
    }

    func edit(messageID: String, text: String) async throws -> ConversationMessage {
        throw unsupported("editing")
    }

    func unsend(messageID: String) async throws -> ConversationMessage {
        throw unsupported("unsend")
    }

    func setTyping(_ isTyping: Bool) async {}

    func markRead(upToSeq: Int) async {
        guard upToSeq > 0 else { return }
        _ = try? await client.markRead(conversation: conversationID, upToSeq: UInt64(upToSeq))
    }

    /// Returns the structured question retained for a transcript message. The
    /// generic Messages renderer uses this to open the full Chief answer sheet
    /// for multi-item, multi-select, and Other questions that cannot be a
    /// single radio-style poll.
    func question(for messageID: String) -> MobileChiefQuestion? {
        withState { state in
            guard let parts = state.structuredPartsByMessageID[messageID] else { return nil }
            return Self.pendingPollPart(from: parts)?.question
        }
    }

    /// Answers a complete Chief question and returns the refreshed transcript
    /// row. The wire contract accepts option labels or ids and one optional
    /// free-text Other value, matching the Mac Chief implementation.
    func answerQuestion(messageID: String, choices: [String], text: String?) async throws -> ConversationMessage {
        guard let question = question(for: messageID), question.isPending else {
            throw ConversationBackendError(code: -1, message: Self.questionNotWaiting)
        }
        guard !choices.isEmpty || (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else {
            throw ConversationBackendError(code: -1, message: Self.answerRequired)
        }
        _ = try await client.answer(
            conversation: conversationID,
            message: messageID,
            choices: choices,
            text: text?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let refreshed: MobileChiefReadResult
        do {
            refreshed = try await client.read(conversation: conversationID, limit: 200)
        } catch {
            // `chief.answer` commits before the follow-up snapshot is
            // necessarily available. Return the retained row so the sheet
            // closes without asking the user to submit the same answer again;
            // the next poll will replace its pending card with the receipt.
            if let previous = withState({ $0.previousMessagesByID[messageID] }) {
                return publishUpdatedMessage(previous)
            }
            throw error
        }
        if let message = refreshed.messages.first(where: { $0.id == messageID }) {
            return publishUpdatedMessage(message)
        }
        if let previous = withState({ $0.previousMessagesByID[messageID] }),
           previous.seq < UInt64.max,
           let targeted = try? await client.read(
               conversation: conversationID,
               beforeSeq: previous.seq + 1,
               limit: 1
           ),
           let message = targeted.messages.first(where: { $0.id == messageID }) {
            withState { $0.previousMessagesByID[messageID] = message }
            return publishUpdatedMessage(message)
        }
        if let previous = withState({ $0.previousMessagesByID[messageID] }) {
            return publishUpdatedMessage(previous)
        }
        throw ConversationBackendError(code: -1, message: Self.answeredQuestionMissing)
    }

    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        throw unsupported("attachments")
    }

    func close() {
        let resources: (
            Task<Void, Never>?,
            AsyncStream<ConversationBackendEvent>.Continuation?
        ) = withState { state in
            state.closed = true
            state.correlatedMessagesByClientID.removeAll()
            let resources = (state.pollTask, state.continuation)
            state.pollTask = nil
            state.continuation = nil
            return resources
        }
        resources.0?.cancel()
        resources.1?.finish()
    }

    private func poll(continuation: AsyncStream<ConversationBackendEvent>.Continuation) async {
        var first = true
        var connected = false
        var reportedFailure = false
        var lastSeq: UInt64 = 0
        var changeCursor: String?
        var publishedInfo: ConversationInfo?
        var publishedMeID: String?
        while !Task.isCancelled && !isClosed {
            do {
                let result = try await client.read(
                    conversation: conversationID,
                    limit: 200,
                    afterSeq: first ? nil : lastSeq,
                    afterCursor: first ? nil : changeCursor,
                    waitForChange: !first
                )
                guard !Task.isCancelled, !isClosed else { return }
                if let cursor = result.changeCursor {
                    changeCursor = cursor
                }
                let pollMessages = try await messagesCoveringGap(result, afterSeq: lastSeq)
                let mappedInfo = info(from: pollMessages)
                if first {
                    first = false
                    // A send may commit before this initial poll observes the
                    // transcript. Correlate that echo before seeding the
                    // baseline so a failed send follow-up can still take the
                    // server row instead of returning a duplicate optimistic
                    // message.
                    for message in pollMessages {
                        _ = clientMessageID(for: message)
                    }
                    // History may have loaded an older page before the first
                    // poll completes. Merge the newest page so a pending card
                    // from that page remains answerable and can be reread by
                    // `before_seq` after the RPC commits.
                    withState { state in
                        mergeMessages(pollMessages, into: &state)
                    }
                    lastSeq = pollMessages.map(\.seq).max() ?? 0
                    continuation.yield(.connected(
                        info: mappedInfo.info,
                        meID: mappedInfo.meID,
                        lagged: false
                    ))
                    publishedInfo = mappedInfo.info
                    publishedMeID = mappedInfo.meID
                    withState { $0.publishedMeID = mappedInfo.meID }
                    continuation.yield(.readState(readState(from: result, fallbackHead: lastSeq)))
                    continuation.yield(.typing(
                        participantID: participantID(in: pollMessages),
                        isTyping: result.working
                    ))
                    connected = true
                } else {
                    if !connected {
                        continuation.yield(.connected(
                            info: mappedInfo.info,
                            meID: mappedInfo.meID,
                            lagged: true
                        ))
                        publishedInfo = mappedInfo.info
                        publishedMeID = mappedInfo.meID
                        withState { $0.publishedMeID = mappedInfo.meID }
                        connected = true
                    } else if mappedInfo.meID != publishedMeID || mappedInfo.info != publishedInfo {
                        // An empty/new conversation starts with the canonical
                        // fallback "me". Once a human message arrives, publish
                        // the authoritative participant so the generic store
                        // reclassifies outgoing bubbles and unread markers.
                        continuation.yield(.connected(
                            info: mappedInfo.info,
                            meID: mappedInfo.meID,
                            lagged: false
                        ))
                        publishedInfo = mappedInfo.info
                        publishedMeID = mappedInfo.meID
                        withState { $0.publishedMeID = mappedInfo.meID }
                    }
                    for message in pollMessages {
                        let previous = withState { $0.previousMessagesByID[message.id] }
                        guard previous != message else { continue }
                        publish(message, on: continuation)
                    }
                    // Keep messages loaded from older history pages. A user
                    // can answer a card after polling has advanced past its
                    // newest-page window, and `votePoll` needs its sequence to
                    // perform the targeted reread.
                    withState { state in
                        mergeMessages(pollMessages, into: &state)
                    }
                    lastSeq = max(lastSeq, pollMessages.map(\.seq).max() ?? 0)
                    continuation.yield(.readState(readState(from: result, fallbackHead: lastSeq)))
                    continuation.yield(.typing(
                        participantID: participantID(in: pollMessages),
                        isTyping: result.working
                    ))
                }
                reportedFailure = false
            } catch {
                connected = false
                if !reportedFailure {
                    continuation.yield(.disconnected(reason: String(describing: error)))
                    reportedFailure = true
                }
                // Keep the stream alive across transient transport failures.
                // The injected clock makes this bounded retry deterministic in
                // tests and avoids a tight loop when the Mac is unavailable.
                do {
                    try await clock.sleep(for: .seconds(3))
                } catch {
                    return
                }
            }
        }
    }

    /// `chief.read` is a newest-page API. If more than one page arrived
    /// between polls, walk older pages until the previous cursor is covered so
    /// the transcript does not silently skip messages or card updates.
    private func messagesCoveringGap(
        _ result: MobileChiefReadResult,
        afterSeq: UInt64
    ) async throws -> [MobileChiefMessage] {
        guard afterSeq > 0, afterSeq < UInt64.max,
              let first = result.messages.first,
              first.seq > afterSeq,
              first.seq - afterSeq > 1 else {
            return result.messages
        }
        var pages = [result.messages]
        var beforeSeq = first.seq
        var hasMore = result.hasMore
        while hasMore, let oldest = pages.first?.first, oldest.seq > afterSeq + 1 {
            guard !Task.isCancelled else { return pages.flatMap { $0 } }
            let page = try await client.read(conversation: conversationID, beforeSeq: beforeSeq, limit: 200)
            guard !page.messages.isEmpty else { break }
            pages.insert(page.messages, at: 0)
            beforeSeq = page.messages[0].seq
            hasMore = page.hasMore
        }
        var byID: [String: MobileChiefMessage] = [:]
        for message in pages.joined() { byID[message.id] = message }
        return byID.values.sorted { $0.seq < $1.seq }
    }

    private func info(from messages: [MobileChiefMessage]) -> (info: ConversationInfo, meID: String) {
        let human = messages.first(where: { $0.authorKind == "human" })?.authorID
            ?? withState { $0.meID }
        withState { $0.meID = human }
        var participants: [ConversationParticipant] = []
        var seen = Set<String>()
        for message in messages {
            guard seen.insert(message.authorID).inserted else { continue }
            participants.append(ConversationParticipant(
                id: message.authorID,
                name: message.author.isEmpty ? message.authorID : message.author,
                initials: initials(for: message.author),
                colorHex: message.authorKind == "human" ? "#0284FE" : "#8E8E93",
                isMe: message.authorID == human
            ))
        }
        if !seen.contains(human) {
            participants.append(ConversationParticipant(
                id: human,
                name: String(localized: "mobile.agentFeed.reply.youLabel", defaultValue: "You", bundle: .module),
                initials: "YO",
                colorHex: "#0284FE",
                isMe: true
            ))
        }
        let chiefID = participantID(in: messages)
        if !seen.contains(chiefID) && chiefID != human {
            participants.append(ConversationParticipant(
                id: chiefID,
                name: String(localized: "mobile.chief.name", defaultValue: "Chief", bundle: .module),
                initials: "CH",
                colorHex: "#8E8E93",
                isMe: false
            ))
        }
        return (ConversationInfo(
            id: conversationID,
            title: fallbackTitle.isEmpty ? conversationID : fallbackTitle,
            kind: .direct,
            participants: participants
        ), human)
    }

    private func participantID(in messages: [MobileChiefMessage]) -> String {
        messages.first(where: { $0.authorKind == "chief" })?.authorID ?? "agent_chief"
    }

    private func map(
        _ message: MobileChiefMessage,
        clientMessageID: String? = nil
    ) -> ConversationMessage {
        // Current hosts echo the id on human messages; keep the explicit id
        // for optimistic rows and legacy hosts that omit it.
        let resolvedClientMessageID = clientMessageID
            ?? (message.authorKind == "human" ? message.clientMessageID : nil)
        let senderIsMe = withState { state in
            let isMe = message.authorID == state.meID || message.authorKind == "human"
            if isMe { state.meID = message.authorID }
            return isMe
        }
        withState { state in
            state.structuredPartsByMessageID[message.id] = message.partPayloads
        }
        let poll = Self.pendingPoll(from: message)
        let text = Self.receiptText(from: message) ?? Self.displayText(from: message)
        return ConversationMessage(
            id: message.id,
            seq: safeInt(message.seq),
            clientMessageID: resolvedClientMessageID,
            senderID: message.authorID,
            sentAt: message.at,
            text: text,
            replyToID: message.threadRoot,
            delivery: senderIsMe ? .sent : nil,
            poll: poll
        )
    }

    /// A pending Chief approval/question is projected into the generic poll
    /// card. Answered and cancelled cards intentionally return nil so their
    /// transcript remains a compact receipt rather than a stale action.
    static func pendingPoll(from message: MobileChiefMessage) -> ConversationPoll? {
        guard let part = pendingPollPart(from: message.partPayloads) else { return nil }
        if let approval = part.approval, part.kind == "approval" {
            let options = approval.options.filter { !$0.hasPrefix("always:") }
            return ConversationPoll(
                question: approval.prompt,
                options: options.map { ConversationPollOption(id: $0, text: $0) }
            )
        }
        if let question = part.question, part.kind == "question", question.isPending {
            if let item = pollQuestion(from: question) {
                return ConversationPoll(
                    question: item.prompt,
                    options: item.options.map { ConversationPollOption(id: $0.id, text: $0.label) }
                )
            }
            // The generic poll card is an accessible entry point for the full
            // Chief question sheet. It intentionally has one action instead
            // of pretending a multi-item ask is a one-choice poll.
            return ConversationPoll(
                question: question.summary,
                options: [ConversationPollOption(
                    id: Self.questionComposerOptionID,
                    text: String(
                        localized: "mobile.chief.question.answer",
                        defaultValue: "Answer questions",
                        bundle: .module
                    )
                )]
            )
        }
        return nil
    }

    /// Select the same card that `pendingPoll(from:)` exposes. A message can
    /// carry multiple structured cards; answered or unsupported cards must not
    /// shadow a later pending card that the generic poll actually renders.
    private static func pendingPollPart(from parts: [MobileChiefPart]) -> MobileChiefPart? {
        for part in parts {
            if let approval = part.approval, part.kind == "approval", approval.decided == nil {
                let options = approval.options.filter { !$0.hasPrefix("always:") }
                guard !options.isEmpty else { continue }
                return part
            }
            if let question = part.question, part.kind == "question", question.isPending, !question.items.isEmpty {
                return part
            }
        }
        return nil
    }

    /// The generic conversation poll has one radio-style option list. A Chief
    /// question with multiple items or multi-select semantics must stay a
    /// transcript-only card until a full question form is available; filling
    /// its hidden selections with defaults can trigger an unintended action.
    private static func pollQuestion(from question: MobileChiefQuestion) -> MobileChiefQuestion.Item? {
        guard question.isPending,
              question.items.count == 1,
              let item = question.items.first,
              !item.multiSelect,
              !item.allowsOther,
              !item.options.isEmpty else {
            return nil
        }
        return item
    }

    /// Text shown after an approval/question is answered or cancelled. This
    /// is the collapsed receipt form used by the generic transcript.
    static func receiptText(from message: MobileChiefMessage) -> String? {
        for part in message.partPayloads {
            if let approval = part.approval, part.kind == "approval", let decided = approval.decided {
                return "\(approval.prompt)\n✓ \(decided)"
            }
            if let question = part.question, part.kind == "question", !question.isPending {
                if case .cancelled = question.state {
                    // Match MessagesLab's compact receipt. A Chief question
                    // closed by a normal chat message is no longer an open
                    // card; showing its old options here would make the
                    // transcript look actionable after the owner settled it.
                    return question.source.harness == .chief
                        ? String(localized: "mobile.chief.question.answeredInChat",
                                 defaultValue: "Answered in chat", bundle: .module)
                        : String(localized: "mobile.chief.question.cancelled",
                                 defaultValue: "Cancelled", bundle: .module)
                }
                return question.transcriptText
            }
        }
        return nil
    }

    /// Structured Chief parts are available on newer hosts even when the
    /// legacy text field is empty. Keep work progress visible in the generic
    /// transcript instead of reducing it to an unhelpful "Work" label.
    static func displayText(from message: MobileChiefMessage) -> String {
        let workParts = message.partPayloads.compactMap(\.work)
        if !workParts.isEmpty {
            var text = message.text
            for work in workParts {
                let title = work.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let status = work.status.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = work.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = [status, preview].filter { !$0.isEmpty }.joined(separator: " · ")
                let rendered = detail.isEmpty ? title : "\(title) · \(detail)"
                let legacyCandidates = [preview, title].filter { !$0.isEmpty }
                if let legacy = legacyCandidates.first(where: { text.range(of: $0) != nil }),
                   let range = text.range(of: legacy) {
                    text.replaceSubrange(range, with: rendered)
                } else if text.isEmpty {
                    text = rendered
                } else if text == title || text == preview {
                    text = rendered
                } else {
                    text += "\(text.isEmpty ? "" : " · ")\(rendered)"
                }
            }
            return text
        }
        if !message.text.isEmpty { return message.text }
        guard !message.partPayloads.isEmpty else {
            return message.parts.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
                .joined(separator: " · ")
        }
        return message.partPayloads.map { part in
            if let work = part.work {
                let detail = [work.status, work.preview].compactMap { value in
                    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return value.isEmpty ? nil : value
                }.joined(separator: " · ")
                return detail.isEmpty ? work.title : "\(work.title) · \(detail)"
            }
            if let approval = part.approval { return approval.prompt }
            if let question = part.question { return question.summary }
            return part.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }.joined(separator: " · ")
    }

    private func map(_ messages: [MobileChiefMessage]) -> [ConversationMessage] {
        messages.map { map($0) }
    }

    /// Correlate a human message with the optimistic row while its send is
    /// pending. Older hosts may omit the wire client id, so text/timestamp
    /// matching remains a bounded fallback for those responses.
    private func clientMessageID(for message: MobileChiefMessage) -> String? {
        guard message.authorKind == "human" else { return nil }
        return withState { state in
            let cutoff = Date().addingTimeInterval(-300)
            state.pendingSends = state.pendingSends.filter { $0.value.startedAt >= cutoff }
            let pendingClientMessageIDs = Set(state.pendingSends.keys)
            state.correlatedMessagesByClientID = state.correlatedMessagesByClientID.filter {
                pendingClientMessageIDs.contains($0.key) || $0.value.at >= cutoff
            }
            if let clientMessageID = message.clientMessageID,
               state.pendingSends[clientMessageID] != nil {
                state.pendingSends.removeValue(forKey: clientMessageID)
                state.correlatedMessagesByClientID[clientMessageID] = message
                return clientMessageID
            }
            guard let pending = state.pendingSends.values.filter({ pending in
                if pending.serverMessageID == message.id {
                    return true
                }
                // Text is only a fallback for hosts that omit both ids. Do
                // not let an older identical message satisfy a newer send.
                return pending.serverMessageID == nil
                    && pending.text == message.text
                    && message.at >= pending.startedAt
            })
                .min(by: { $0.startedAt < $1.startedAt }) else { return nil }
            state.pendingSends.removeValue(forKey: pending.clientMessageID)
            state.correlatedMessagesByClientID[pending.clientMessageID] = message
            return pending.clientMessageID
        }
    }

    private func takeCorrelatedMessage(for clientMessageID: String) -> MobileChiefMessage? {
        withState { state in
            state.correlatedMessagesByClientID.removeValue(forKey: clientMessageID)
        }
    }

    private func publishUpdatedMessage(_ message: MobileChiefMessage) -> ConversationMessage {
        withState { state in mergeMessages([message], into: &state) }
        let mapped = map(message, clientMessageID: clientMessageID(for: message))
        let continuation = withState { $0.continuation }
        if let continuation { publish(mapped, on: continuation) }
        return mapped
    }

    private func publish(_ message: MobileChiefMessage, on continuation: AsyncStream<ConversationBackendEvent>.Continuation) {
        let mapped = map(message, clientMessageID: clientMessageID(for: message))
        publish(mapped, on: continuation)
    }

    private func publish(_ message: ConversationMessage, on continuation: AsyncStream<ConversationBackendEvent>.Continuation) {
        withState { state in
            if state.eventSeq < Int.max { state.eventSeq += 1 }
            state.eventSeq = max(state.eventSeq, message.seq ?? 0)
            // Assigning the sequence and yielding it under the same lock
            // preserves event order when concurrent poll/history tasks publish
            // updates for the same conversation.
            continuation.yield(.message(message, eventSeq: state.eventSeq))
        }
    }

    private func readState(from result: MobileChiefReadResult, fallbackHead: UInt64) -> ConversationReadState {
        let head = result.headSeq ?? max(fallbackHead, result.messages.map(\.seq).max() ?? 0)
        return ConversationReadState(
            lastReadSeq: safeInt(result.lastReadSeq ?? 0),
            unreadCount: max(0, result.unreadCount ?? 0),
            headSeq: safeInt(head)
        )
    }

    /// A send can discover the first human message before the next poll tick.
    /// Publish the participant identity immediately so the generic store does
    /// not briefly render that first outgoing bubble as incoming.
    private func publishIdentityIfNeeded(for message: MobileChiefMessage) {
        guard message.authorKind == "human" else { return }
        let knownMessages = withState { Array($0.previousMessagesByID.values) }
        let mapped = info(from: knownMessages + [message])
        let continuation = withState { state -> AsyncStream<ConversationBackendEvent>.Continuation? in
            guard mapped.meID != state.publishedMeID else { return nil }
            state.publishedMeID = mapped.meID
            return state.continuation
        }
        continuation?.yield(.connected(info: mapped.info, meID: mapped.meID, lagged: false))
    }

    /// Keep enough transcript history to answer cards loaded from an older
    /// page without retaining an unbounded conversation in a long-lived view.
    /// Pending cards stay protected so polling cannot make a visible action
    /// disappear before the user taps it.
    private func mergeMessages(_ messages: [MobileChiefMessage], into state: inout State) {
        state.previousMessagesByID.merge(
            messages.reduce(into: [:]) { $0[$1.id] = $1 },
            uniquingKeysWith: { _, new in new }
        )
        guard state.previousMessagesByID.count > State.cachedMessageLimit else { return }
        let protectedIDs = Set(state.structuredPartsByMessageID.compactMap { id, parts in
            Self.pendingPollPart(from: parts) == nil ? nil : id
        })
        let removeCount = state.previousMessagesByID.count - State.cachedMessageLimit
        let removable = state.previousMessagesByID.values
            .filter { !protectedIDs.contains($0.id) }
            .sorted { $0.seq < $1.seq }
            .prefix(removeCount)
        for message in removable {
            state.previousMessagesByID.removeValue(forKey: message.id)
            state.structuredPartsByMessageID.removeValue(forKey: message.id)
        }
    }

    private var isClosed: Bool {
        withState { $0.closed }
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }

    private func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private func safeInt(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private func unsupported(_ operation: String) -> ConversationBackendError {
        ConversationBackendError(code: -32601, message: Self.unsupportedBackendText(operation))
    }
}
