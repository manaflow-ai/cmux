import Foundation

extension SessionStateMirror {
    /// A workspace's description and manual task status, from its `extra`
    /// (`workspace-description-v1`, `workspace-status-v1`), and who made it
    /// (`extra.created_by`). Empty while none is set.
    public struct WorkspaceNotes: Sendable, Hashable {
        /// The person's notes for the workspace; nil while unset.
        public var description: String?
        /// The lane the person pinned; nil while automatic.
        public var taskStatus: WorkspaceTaskStatus?
        /// Who made the workspace and why (`extra.created_by`); nil on a daemon that does not say.
        public var createdBy: WorkspaceCreator?

        /// Notes with `description`, `taskStatus` and `createdBy`; all default to unset.
        public init(description: String? = nil, taskStatus: WorkspaceTaskStatus? = nil, createdBy: WorkspaceCreator? = nil) {
            self.description = description
            self.taskStatus = taskStatus
            self.createdBy = createdBy
        }

        /// No field is set.
        public var isEmpty: Bool { description == nil && taskStatus == nil && createdBy == nil }
    }
}
