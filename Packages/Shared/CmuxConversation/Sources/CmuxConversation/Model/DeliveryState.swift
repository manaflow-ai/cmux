/// Where a message the user sent is on its way to the agent.
public enum DeliveryState: Hashable, Sendable {
    /// Shown locally; the backend has not confirmed it yet.
    case sending
    /// Waiting behind other prompts; `position` counts from 1.
    case queued(position: Int)
    /// Recorded and in its queue place, waiting for its attached files.
    case uploading
    /// Sent into the running turn (steering it).
    case steered
    /// The agent received it.
    case delivered
    /// Its files never arrived. Retrying sends it again.
    case failed
}
