import Foundation

extension SessionStateMirror {
    /// A workspace's description and manual task status, from its `extra`
    /// (`workspace-description-v1`, `workspace-status-v1`), and who made it
    /// (`extra.created_by.kind`, `workspace-created-by-v1`). Empty while none
    /// is set.
    public struct WorkspaceNotes: Sendable, Hashable {
        /// The person's notes for the workspace; nil while unset.
        public var description: String?
        /// The lane the person pinned; nil while automatic.
        public var taskStatus: WorkspaceTaskStatus?
        /// Who made the workspace, as the daemon recorded it at the create (`person`, `agent` or `script`); nil
        /// without a record (the person in the app, or a workspace made before the daemon kept one).
        public var createdBy: String?

        /// Notes with `description`, `taskStatus` and `createdBy`; all default to unset.
        public init(description: String? = nil, taskStatus: WorkspaceTaskStatus? = nil, createdBy: String? = nil) {
            self.description = description
            self.taskStatus = taskStatus
            self.createdBy = createdBy
        }

        /// No field is set.
        public var isEmpty: Bool { description == nil && taskStatus == nil && createdBy == nil }
    }
}
