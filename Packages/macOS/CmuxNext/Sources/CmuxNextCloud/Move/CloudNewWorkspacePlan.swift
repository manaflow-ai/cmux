import Foundation

/// Where the Cloud toggle (#26062, `cloud.newWorkspacesInCloud`) sends a person's New Workspace:
/// nil keeps it on this Mac; otherwise a new Cloud machine of its own, starting in ``folder``
/// copied there, or in the machine's empty work folder when ``folder`` is nil.
public nonisolated struct CloudNewWorkspacePlan: Sendable, Equatable {
    /// The folder copied to the new machine (the working copy around the person's folder); nil
    /// starts in the machine's own empty folder.
    public let folder: CloudMoveFolder?

    /// - Parameters:
    ///   - inCloud: `cloud.newWorkspacesInCloud`.
    ///   - inheritsFolder: `cloud.newWorkspaceFolder` is `inherit`.
    ///   - cwd: The folder the person works in on this Mac (the focused terminal's or chat's), if any.
    ///   - namesMachine: The invocation names a machine (`--machine`): it opens there, never on a new one.
    public init?(inCloud: Bool, inheritsFolder: Bool, cwd: String?, namesMachine: Bool) {
        guard inCloud, !namesMachine else { return nil }
        // A home folder or the disk's root is never copied: the workspace starts empty instead.
        folder = inheritsFolder ? cwd.flatMap(CloudMoveFolder.init(chat:)).flatMap { $0.isTooBroad ? nil : $0 } : nil
    }

    /// The new workspace's name: the copied folder's, else none (the daemon names it).
    public var workspaceName: String? {
        folder.map { URL(fileURLWithPath: $0.root).lastPathComponent }
    }
}
