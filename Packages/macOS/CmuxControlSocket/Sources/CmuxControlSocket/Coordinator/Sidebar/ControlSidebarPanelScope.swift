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

    /// Creates a scope.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace (tab) id.
    ///   - panelID: The panel (surface) id.
    ///   - terminalLifecycleID: The terminal process generation, or `nil` for
    ///     backward-compatible callers that do not report one.
    public init(
        workspaceID: UUID,
        panelID: UUID,
        terminalLifecycleID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.terminalLifecycleID = terminalLifecycleID
    }
}
