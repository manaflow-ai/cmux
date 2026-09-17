/// Stable observability stages for failures that would otherwise drop hook state silently.
enum AgentHookFailureStage: String, Sendable {
    case targetResolution = "target-resolution"
    case notificationDelivery = "notification-delivery"
    case journalAppend = "journal-append"
}
