public import Foundation

/// The result of a launched cloud-VM creation, threaded back into the in-group
/// async-join observer so a VM workspace created out-of-band can still be placed
/// in its target group.
///
/// A `Sendable` projection of the app-side `CloudVMActionLauncher.Completion`,
/// carrying only the two fields the new-workspace routing reads: whether the
/// launch succeeded and the created workspace's id (when the launch named one).
/// Keeping the value package-side lets ``WorkspaceCreationActionCoordinator``
/// own the in-group async-join sequencing without importing the app-side
/// launcher.
public struct CloudVMActionCompletion: Sendable {
    /// Whether the `cmux vm new` launch finished successfully.
    public let succeeded: Bool
    /// The created workspace's id, when the launch reported one.
    public let workspaceId: UUID?

    /// Creates a cloud-VM completion projection.
    public init(succeeded: Bool, workspaceId: UUID?) {
        self.succeeded = succeeded
        self.workspaceId = workspaceId
    }
}
