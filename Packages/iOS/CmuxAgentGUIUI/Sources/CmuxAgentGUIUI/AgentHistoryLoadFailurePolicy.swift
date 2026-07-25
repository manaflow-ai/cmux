import CmuxAgentGUIProjection

enum AgentHistoryLoadFailurePolicy {
    static func shouldShowBanner(
        failure: AgentHistoryLoadFailure?,
        input: TranscriptProjectionInput
    ) -> Bool {
        guard failure != nil else { return false }
        return !input.hasRenderableTranscriptContent
    }
}

