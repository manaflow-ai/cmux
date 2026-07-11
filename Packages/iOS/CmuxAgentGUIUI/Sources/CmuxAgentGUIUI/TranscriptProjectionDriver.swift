import CmuxAgentGUIProjection
import CmuxAgentReplica
import CmuxAgentSync
import Observation

@MainActor
final class TranscriptProjectionDriver {
    private let engine: AgentSyncEngine
    private let sessionID: AgentSessionID
    private let sink: (TranscriptProjectionInput) -> Void
    private var conversation: ConversationReplica?
    private var isStarted = false

    init(
        engine: AgentSyncEngine,
        sessionID: AgentSessionID,
        sink: @escaping (TranscriptProjectionInput) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.sink = sink
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        conversation = engine.openConversation(sessionID: sessionID)
        observe()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        conversation = nil
        engine.closeConversation(sessionID: sessionID)
    }

    private func observe() {
        guard isStarted, let conversation else { return }
        var nextInput: TranscriptProjectionInput?
        withObservationTracking {
            nextInput = makeInput(conversation: conversation)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
            }
        }
        guard let nextInput else { return }
        sink(nextInput)
    }

    private func makeInput(conversation: ConversationReplica) -> TranscriptProjectionInput {
        TranscriptProjectionInput(
            state: conversation.state,
            hasMoreBefore: engine.hasMoreBeforeBySession[sessionID] ?? false,
            streamingTail: engine.streamingTails[sessionID].map(TranscriptStreamingTail.init)
        )
    }
}
