import Foundation
import CmuxSurfaceCatalogModel

/// A supported Cloud create or open invocation without app lifecycle state.
public struct CloudMachineCreateInvocation: Equatable, Sendable {
    /// The existing machine for an open retry; nil for a new create.
    public let machineID: String?
    /// The requested image kind, or the server default.
    public let kind: VMMachineKind?
    /// The requested positive memory size in MiB.
    public let memoryMb: Int?
    /// The optional trimmed machine label.
    public let displayName: String?
    /// The requested outbound network policy.
    public let networkPolicy: CloudNetworkPolicy?
    /// The requested guest agent update policy.
    public let agentUpdates: CloudAgentUpdates?
    /// The exact local workspace reserved for this operation.
    public let workspaceID: UUID
    /// Whether the caller requested terminal focus.
    public let focus: Bool
    /// The initiating window, when the invocation carries one.
    public let windowID: UUID?
}
