import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService {
    static func descriptorChangedMeaningfully(
        previous: AgentChatSessionRecord?,
        current: AgentChatSessionRecord
    ) -> Bool {
        guard var normalizedPrevious = previous else { return true }
        normalizedPrevious.lastActivityAt = current.lastActivityAt
        return normalizedPrevious.descriptor != current.descriptor
    }

    /// Sidebar-only variant of `descriptorChangedMeaningfully`. The registry
    /// increments `version` on every accepted mutation, so an activity bump
    /// still changes the phone descriptor; the Conversations sidebar has no
    /// use for the version and skips those bumps. Phone behavior is unchanged.
    static func sidebarProjectionChangedMeaningfully(
        previous: AgentChatSessionRecord?,
        current: AgentChatSessionRecord
    ) -> Bool {
        guard var normalizedPrevious = previous else { return true }
        normalizedPrevious.lastActivityAt = current.lastActivityAt
        normalizedPrevious.version = current.version
        return normalizedPrevious.descriptor != current.descriptor
    }

    /// Encodes a wire value into the `[String: Any]` payload shape the
    /// event fan-out expects.
    func wirePayload<T: Encodable>(_ value: T) -> [String: Any]? {
        let coding = ChatWireCoding()
        guard let data = try? coding.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
