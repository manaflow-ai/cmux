import Foundation

struct AgentHibernationTranscriptHookStoreRecord: Decodable {
    let sessionId: String?
    let workspaceId: String?
    let surfaceId: String?
    let transcriptPath: String?
    let updatedAt: TimeInterval?

    func matches(panelKey: AgentHibernationPanelKey) -> Bool {
        normalizedUUID(workspaceId) == panelKey.workspaceId &&
            normalizedUUID(surfaceId) == panelKey.panelId
    }

    private func normalizedUUID(_ value: String?) -> UUID? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return UUID(uuidString: value)
    }
}
