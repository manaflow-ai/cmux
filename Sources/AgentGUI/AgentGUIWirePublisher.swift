import CmuxAgentReplica
import CmuxAgentWire
import Foundation

@MainActor
final class AgentGUIWirePublisher {
    private let epoch: ReplicaEpoch

    init(epoch: ReplicaEpoch) {
        self.epoch = epoch
    }

    func publishSessionUpserted(_ session: AgentSessionSnapshot) {
        publish(
            topic: GuiWireTopic.sessions,
            frame: GuiEventFrame(
                epoch: epoch,
                sessionID: session.id,
                payload: .sessionUpserted(GuiSessionUpsertedEvent(session: session))
            )
        )
    }

    func publishSessionRemoved(_ sessionID: AgentSessionID, version: EntityVersion) {
        publish(
            topic: GuiWireTopic.sessions,
            frame: GuiEventFrame(
                epoch: epoch,
                sessionID: sessionID,
                payload: .sessionRemoved(GuiSessionRemovedEvent(sessionID: sessionID, version: version))
            )
        )
    }

    func publishJournalEvent(_ event: AgentGUIJournalPipelineEvent, sessionID: AgentSessionID) {
        let topic = GuiWireTopic.journal(sessionID: sessionID)
        switch event {
        case .reset(let journalID, let tailSeq):
            publish(
                topic: topic,
                frame: GuiEventFrame(
                    epoch: epoch,
                    sessionID: sessionID,
                    payload: .journalReset(GuiJournalResetEvent(sessionID: sessionID, newJournalID: journalID, tailSeq: tailSeq))
                )
            )
        case .appended(let journalID, let entries):
            publish(
                topic: topic,
                frame: GuiEventFrame(
                    epoch: epoch,
                    sessionID: sessionID,
                    payload: .entriesAppended(GuiEntriesAppendedEvent(journalID: journalID, entries: entries))
                )
            )
        case .replaced(let journalID, let entry):
            publish(
                topic: topic,
                frame: GuiEventFrame(
                    epoch: epoch,
                    sessionID: sessionID,
                    payload: .entryReplaced(GuiEntryReplacedEvent(journalID: journalID, entry: entry))
                )
            )
        }
    }

    func publishSendState(_ ticket: SendTicket) {
        publish(
            topic: GuiWireTopic.journal(sessionID: ticket.sessionID),
            frame: GuiEventFrame(
                epoch: epoch,
                sessionID: ticket.sessionID,
                payload: .sendState(GuiSendStateEvent(ticket: ticket))
            )
        )
    }

    func publishAskState(_ ask: PendingAsk) {
        publish(
            topic: GuiWireTopic.journal(sessionID: ask.sessionID),
            frame: GuiEventFrame(
                epoch: epoch,
                sessionID: ask.sessionID,
                payload: .askState(GuiAskStateEvent(ask: ask))
            )
        )
    }

    private func publish(topic: String, frame: GuiEventFrame) {
        guard MobileHostService.hasEventSubscribers(topic: topic) else {
            return
        }
        guard let payload = try? AgentGUICodableBridge.dictionary(frame) else {
            return
        }
        MobileHostService.emitEvent(topic: topic, payload: payload)
    }
}
