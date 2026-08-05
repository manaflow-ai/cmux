import CmuxAgentReplica

struct AgentAskSheetPolicy {
    static func shouldResetError(previousAskID: String?, nextAskID: String) -> Bool {
        previousAskID != nextAskID
    }

    static func shouldDismiss(selectedAskID: String, asks: [PendingAsk]) -> Bool {
        !asks.contains { ask in
            ask.id == selectedAskID && ask.state == .active
        }
    }
}
