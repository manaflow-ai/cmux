import CMUXAgentLaunch
import CmuxAgentReplica
import CmuxAgentWire
import Foundation

@MainActor
final class AgentGUIFallbackPromptLedger {
    private let clock: () -> Int
    private var acceptedTickets: [String: Int] = [:]

    init(clock: @escaping () -> Int) {
        self.clock = clock
    }

    func submit(
        surfaceID: String,
        ticketID: UUID?,
        inject: () -> AgentGUITerminalInjectionResult
    ) -> AgentLaunchExecutionResult {
        let now = clock()
        acceptedTickets = acceptedTickets.filter {
            now - $0.value < AgentGUIConstants.sendTicketIdempotencyWindowMS
        }
        let ticketKey = ticketID.map { "\(surfaceID):\($0.uuidString)" }
        if let ticketKey, acceptedTickets[ticketKey] != nil {
            return .accepted
        }

        let injection = inject()
        guard injection.accepted, let ticketKey else {
            return launchResult(injection)
        }
        acceptedTickets[ticketKey] = now
        if acceptedTickets.count > AgentGUIConstants.resolvedSendTicketRetentionLimit,
           let oldest = acceptedTickets.min(by: { $0.value < $1.value })?.key {
            acceptedTickets.removeValue(forKey: oldest)
        }
        return .accepted
    }

    private func launchResult(_ result: AgentGUITerminalInjectionResult) -> AgentLaunchExecutionResult {
        switch result {
        case .accepted: .accepted
        case .bindingLost: .failed("binding_lost")
        case .inputQueueFull: .failed("input_queue_full")
        case .processExited: .failed("process_exited")
        }
    }
}

@MainActor
final class AgentGUISendLedger {
    private struct Record {
        var ticket: SendTicket
        var injectedText: String?
        var injectedAt: Int?
        var resolvedAt: Int?
        var unmatchedUserMessageCount: Int
    }

    private let sessionID: AgentSessionID
    private let clock: () -> Int
    private let injector: any AgentGUITerminalInjecting
    private let publish: (SendTicket) -> Void
    private var records: [UUID: Record] = [:]
    private var order: [UUID] = []
    private var queued: [UUID] = []
    private var lastPhase: SessionPhase?
    private var highestProcessedSeqByJournalID: [JournalID: EntrySeq] = [:]

    init(
        sessionID: AgentSessionID,
        clock: @escaping () -> Int,
        injector: any AgentGUITerminalInjecting,
        publish: @escaping (SendTicket) -> Void
    ) {
        self.sessionID = sessionID
        self.clock = clock
        self.injector = injector
        self.publish = publish
    }

    var hasPendingExpirations: Bool {
        records.values.contains { record in
            if case .injected = record.ticket.state { return true }
            return record.resolvedAt != nil
        }
    }

    var retainedRecordCount: Int { records.count }

    func submit(
        ticketID: UUID,
        text: String,
        attachmentCount: Int,
        snapshot: AgentSessionSnapshot?
    ) throws -> GuiSendResult {
        pruneResolvedTickets(now: clock())
        if let existing = records[ticketID] {
            return GuiSendResult(accepted: true, queuedOnMac: queued.contains(ticketID) && existing.ticket.state == .acceptedByMac)
        }

        let ticket = SendTicket(
            id: ticketID,
            sessionID: sessionID,
            text: text,
            attachmentCount: attachmentCount,
            state: .acceptedByMac,
            createdAt: clock()
        )
        records[ticketID] = Record(ticket: ticket, injectedText: nil, injectedAt: nil, resolvedAt: nil, unmatchedUserMessageCount: 0)
        order.append(ticketID)
        publish(ticket)

        guard let snapshot else {
            transition(ticketID, to: .failed(code: "binding_lost"))
            throw AgentGUIRPCError.bindingLost
        }
        if lastPhase == nil {
            lastPhase = snapshot.phase
        }
        guard !shouldQueue(phase: snapshot.phase), queued.isEmpty else {
            queued.append(ticketID)
            return GuiSendResult(accepted: true, queuedOnMac: true)
        }
        let result = inject(ticketID, snapshot: snapshot)
        if !result.accepted {
            throw AgentGUIRPCError.fromInjectionFailure(result)
        }
        return GuiSendResult(accepted: true, queuedOnMac: false)
    }

    func handleSessionSnapshot(_ snapshot: AgentSessionSnapshot) {
        let previous = lastPhase
        lastPhase = snapshot.phase
        if previous != .ended, snapshot.phase == .ended {
            failQueuedTickets()
            return
        }
        let enteredIdle = previous != nil && previous != .idle && snapshot.phase == .idle
        let workingBecameNeedsInput = previous == .working && snapshot.phase == .needsInput
        guard enteredIdle || workingBecameNeedsInput else { return }
        injectNextQueued(snapshot: snapshot)
    }

    func handleJournalEvent(_ event: AgentGUIJournalPipelineEvent) {
        switch event {
        case .appended(let journalID, let entries):
            for entry in entries.sorted(by: { $0.seq < $1.seq }) {
                if let highest = highestProcessedSeqByJournalID[journalID], entry.seq <= highest {
                    continue
                }
                highestProcessedSeqByJournalID[journalID] = entry.seq
                handleAppendedEntry(entry)
            }
        case .reset(let journalID, _):
            highestProcessedSeqByJournalID.removeValue(forKey: journalID)
        case .replaced:
            break
        }
    }

    func expire(now: Int? = nil) {
        let current = now ?? clock()
        for ticketID in Array(order) {
            guard let record = records[ticketID],
                  case .injected = record.ticket.state,
                  let injectedAt = record.injectedAt,
                  current - injectedAt >= AgentGUIConstants.sendEchoTimeoutMS else {
                continue
            }
            transition(ticketID, to: .unconfirmed)
        }
        pruneResolvedTickets(now: current)
    }

    private func injectNextQueued(snapshot: AgentSessionSnapshot) {
        while !queued.isEmpty {
            let ticketID = queued.removeFirst()
            guard let record = records[ticketID], record.ticket.state == .acceptedByMac else {
                continue
            }
            _ = inject(ticketID, snapshot: snapshot)
            return
        }
    }

    private func failQueuedTickets() {
        queued.removeAll()
        for ticketID in order {
            guard records[ticketID]?.ticket.state == .acceptedByMac else { continue }
            transition(ticketID, to: .failed(code: AgentGUITerminalInjectionResult.processExited.failureCode))
        }
    }

    private func inject(_ ticketID: UUID, snapshot: AgentSessionSnapshot) -> AgentGUITerminalInjectionResult {
        guard let surfaceID = snapshot.surfaceID, !surfaceID.isEmpty,
              let record = records[ticketID] else {
            transition(ticketID, to: .failed(code: "binding_lost"))
            return .bindingLost
        }
        let result = injector.submitPrompt(surfaceID: surfaceID, text: record.ticket.text)
        guard result.accepted else {
            transition(ticketID, to: .failed(code: result.failureCode))
            return result
        }
        updateRecord(ticketID) { current in
            current.injectedText = current.ticket.text
            current.injectedAt = clock()
            current.unmatchedUserMessageCount = 0
        }
        transition(ticketID, to: .injected)
        return .accepted
    }

    private func handleAppendedEntry(_ entry: EntrySnapshot) {
        guard case .userMessage(let payload) = entry.content.payload,
              let ticketID = oldestInjectedTicketID(),
              var record = records[ticketID],
              let injectedText = record.injectedText else {
            return
        }
        if payload.text == injectedText || normalized(payload.text) == normalized(injectedText) {
            transition(ticketID, to: .echoed(entry.seq))
            return
        }
        record.unmatchedUserMessageCount += 1
        records[ticketID] = record
        if record.unmatchedUserMessageCount >= AgentGUIConstants.sendEchoUnmatchedAppendLimit {
            transition(ticketID, to: .unconfirmed)
        }
    }

    private func oldestInjectedTicketID() -> UUID? {
        order.first { ticketID in
            guard let record = records[ticketID] else { return false }
            if case .injected = record.ticket.state {
                return true
            }
            return false
        }
    }

    private func pruneResolvedTickets(now: Int) {
        for ticketID in Array(order) {
            guard let resolvedAt = records[ticketID]?.resolvedAt,
                  now - resolvedAt >= AgentGUIConstants.sendTicketIdempotencyWindowMS else { continue }
            remove(ticketID)
        }
        enforceResolvedRetentionLimit()
    }

    private func enforceResolvedRetentionLimit() {
        var resolvedIDs = order.filter { records[$0]?.resolvedAt != nil }
        while resolvedIDs.count > AgentGUIConstants.resolvedSendTicketRetentionLimit {
            remove(resolvedIDs.removeFirst())
        }
    }

    private func remove(_ ticketID: UUID) {
        records.removeValue(forKey: ticketID)
        order.removeAll { $0 == ticketID }
        queued.removeAll { $0 == ticketID }
    }

    private func transition(_ ticketID: UUID, to state: SendTicketState) {
        guard var record = records[ticketID] else { return }
        let current = record.ticket
        let next = SendTicket(
            id: current.id,
            sessionID: current.sessionID,
            text: current.text,
            attachmentCount: current.attachmentCount,
            state: state,
            createdAt: current.createdAt
        )
        record.ticket = next
        if state.isResolved, !current.state.isResolved {
            record.resolvedAt = clock()
        }
        records[ticketID] = record
        publish(next)
        enforceResolvedRetentionLimit()
    }

    private func updateRecord(_ ticketID: UUID, _ body: (inout Record) -> Void) {
        guard var record = records[ticketID] else { return }
        body(&record)
        records[ticketID] = record
    }

    private func shouldQueue(phase: SessionPhase) -> Bool {
        phase == .working
    }

    private func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
