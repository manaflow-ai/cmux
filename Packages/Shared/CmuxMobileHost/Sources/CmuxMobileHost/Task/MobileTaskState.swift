/// A task's lifecycle state (common.schema.json `TaskState`). Written only by
/// the Mac's task runner.
public enum MobileTaskState: String, Hashable, Sendable, Codable, CaseIterable {
    case queued
    case running
    case needsInput = "needs_input"
    case done
    case failed
}
