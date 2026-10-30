import Foundation

extension AgentPaneView {
    /// Tells this pane's page that session `session`'s avatar was set or removed (in any pane), so its
    /// cards and sender chips ask for it again (agentAvatar.ts `agentAvatarChanged`).
    public func agentAvatarChanged(_ session: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [session]),
              let list = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.cmuxAcpmuxBridge?.agentAvatarChanged?.(...\(list));")
    }

    /// Tells this pane's page that a Chief was renamed or got a new avatar, so the message lines it
    /// draws of a Chief ask for its face again (chiefFace.ts `refreshChiefFaces`, manaflow-ai/cmux#27914).
    public func chiefFacesChanged() {
        evaluateScript("window.cmuxAcpmuxBridge?.chiefFacesChanged?.();")
    }
}
