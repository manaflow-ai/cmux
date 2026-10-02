import CmuxNextDaemon
import CmuxNextHome
import Foundation
import Observation

/// One window's Home: its view model (which conversation is open is this
/// window's view state) and the intents its view sends, forwarded to the
/// shared `HomeService` as user-origin ops.
@MainActor
final class HomeWindowModel: HomeActions {
    let viewModel = HomeViewModel()
    private unowned let service: HomeService
    private var listObservation: Task<Void, Never>?

    init(service: HomeService) {
        self.service = service
        viewModel.actions = self
        // task-owner: lives as long as the window's Home; event-driven (Observation)
        listObservation = Task { [weak self] in
            for await list in Observations({ [weak service] in service?.conversations ?? [] }) {
                self?.apply(list)
            }
        }
    }

    isolated deinit { listObservation?.cancel() }

    private func apply(_ list: [ConversationSummary]) {
        viewModel.conversations = list.map { HomeMapping.summary($0, owner: HomeStrings.thisMacOnly) }
        let selected = viewModel.selectedConversationID
        if selected == nil || !list.contains(where: { $0.id == selected }), let first = list.first {
            selectConversation(first.id)
        }
    }

    // MARK: HomeActions

    func send(text: String, replyTo: String?, in conversationID: String) {
        service.send(text, in: conversationID, replyTo: replyTo.map { ConversationPartRef(messageID: $0, partIndex: 0) })
    }

    func selectConversation(_ conversationID: String) {
        guard viewModel.selectedConversationID != conversationID || viewModel.transcript == nil else { return }
        viewModel.selectedConversationID = conversationID
        viewModel.transcript = HomeTranscriptAdapter(session: service.session(conversationID), service: service)
    }

    func createConversation() {
        service.createConversation()
    }

    func markRead(seq: Int, in conversationID: String) {
        service.markRead(UInt64(max(0, seq)), in: conversationID)
    }

    func retry(clientMsgID: String, in conversationID: String) {
        service.retry(clientMsgID, in: conversationID)
    }
}
