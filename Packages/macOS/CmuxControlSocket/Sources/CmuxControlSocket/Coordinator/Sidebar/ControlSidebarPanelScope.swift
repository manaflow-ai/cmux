public import Foundation

/// The explicit workspace+panel scope shell integration passes to the v1
/// sidebar telemetry commands (`--tab=<uuid> --panel=<uuid>`), including the
/// optional terminal-process generation carried by shell-state reports.
public struct ControlSidebarPanelScope: Sendable, Equatable {
    /// The workspace (tab) id.
    public let workspaceID: UUID
    /// The panel (surface) id.
    public let panelID: UUID
    /// The reporting terminal process generation, when supplied.
    public let terminalLifecycleID: UUID?
    /// Relay owner and connection generation, when the report arrived over a relay.
    public let remoteRelayOwnerWorkspaceID: UUID?
    /// The authenticated relay connection generation, when relay-scoped.
    public let remoteRelayConnectionID: UUID?

    /// Creates a scope.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace (tab) id.
    ///   - panelID: The panel (surface) id.
    ///   - terminalLifecycleID: The terminal process generation, or `nil` for
    ///     backward-compatible callers that do not report one.
    ///   - remoteRelayOwnerWorkspaceID: The authenticated relay owner, if any.
    ///   - remoteRelayConnectionID: The authenticated relay connection, if any.
    public init(
        workspaceID: UUID,
        panelID: UUID,
        terminalLifecycleID: UUID? = nil,
        remoteRelayOwnerWorkspaceID: UUID? = nil,
        remoteRelayConnectionID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.terminalLifecycleID = terminalLifecycleID
        self.remoteRelayOwnerWorkspaceID = remoteRelayOwnerWorkspaceID
        self.remoteRelayConnectionID = remoteRelayConnectionID
    }
}
