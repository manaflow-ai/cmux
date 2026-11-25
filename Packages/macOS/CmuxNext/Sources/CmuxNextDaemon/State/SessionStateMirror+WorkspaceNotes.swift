import Foundation

extension SessionStateMirror {
    /// A workspace's description and manual task status, from its `extra`
    /// (`workspace-description-v1`, `workspace-status-v1`). Empty while
    /// neither is set.
    public struct WorkspaceNotes: Sendable, Hashable {
        /// The person's notes for the workspace; nil while unset.
        public var description: String?
        /// The lane the person pinned; nil while automatic.
        public var taskStatus: WorkspaceTaskStatus?

        /// Notes with `description` and `taskStatus`; both default to unset.
        public init(description: String? = nil, taskStatus: WorkspaceTaskStatus? = nil) {
            self.description = description
            self.taskStatus = taskStatus
        }

        /// Neither field is set.
        public var isEmpty: Bool { description == nil && taskStatus == nil }
    }
}
