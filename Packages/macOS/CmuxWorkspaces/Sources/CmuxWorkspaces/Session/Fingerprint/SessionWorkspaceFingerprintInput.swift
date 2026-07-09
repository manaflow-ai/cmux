public import Foundation

/// The complete, `Sendable`, value-typed snapshot the session autosave
/// fingerprint is computed over, flattened off the live per-window god state.
///
/// This is the seam payload that lets ``SessionFingerprintService`` compute the
/// autosave fingerprint without reaching into any app-target type: it carries
/// exactly the values the legacy `TabManager.sessionAutosaveFingerprint`
/// combined, in declaration order, so the service reproduces the legacy hash
/// byte-identically (the autosave skip-on-unchanged-fingerprint optimization
/// depends on that stability). The app-side ``SessionFingerprintHosting``
/// witness is the only code that still reads `selectedTabId`, `tabs`,
/// `workspaceGroups`, the notification store, and the resume/agent indexes; it
/// builds this value and hands it down.
public struct SessionWorkspaceFingerprintInput: Sendable, Equatable {
    /// Legacy `selectedTabId`.
    public let selectedTabId: UUID?
    /// Legacy `tabs.count` (the full count, not the session-eligible prefix).
    public let workspaceCount: Int
    /// Legacy `workspaceGroups`, flattened, in their existing order.
    public let groups: [SessionFingerprintGroupSnapshot]
    /// Legacy `tabs.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)`,
    /// flattened, in order. The witness applies the prefix so the package needs
    /// no policy constant.
    public let workspaces: [SessionFingerprintWorkspaceSnapshot]

    /// Creates a complete fingerprint input.
    public init(
        selectedTabId: UUID?,
        workspaceCount: Int,
        groups: [SessionFingerprintGroupSnapshot],
        workspaces: [SessionFingerprintWorkspaceSnapshot]
    ) {
        self.selectedTabId = selectedTabId
        self.workspaceCount = workspaceCount
        self.groups = groups
        self.workspaces = workspaces
    }
}
