internal import Foundation

/// The localized workspace-domain error messages, resolved against the app
/// bundle so ``ControlCommandCoordinator`` can shape the localized error
/// envelopes without binding `String(localized:)` to the package bundle (which
/// lacks the keys, silently dropping non-English translations = a wire change).
///
/// The notification / workspace-group domains use the same pattern. Each field
/// carries the exact `String(localized:)` result the legacy body produced.
public struct ControlWorkspaceStrings: Sendable, Equatable {
    /// `workspace.closeProtected.message` — the `workspace.close` protected-pin
    /// error.
    public let closeProtected: String
    /// The `workspace.close` local-teardown failure message.
    public let closeFailed: String
    /// `socket.workspace.reorderMany.missingOrder`.
    public let reorderManyMissingOrder: String
    /// `socket.workspace.reorderMany.duplicateWorkspace`.
    public let reorderManyDuplicateWorkspace: String
    /// `socket.workspace.reorderMany.workspaceNotFound` — shared by
    /// `workspace.reorder`, which reports the same failure for the same reason.
    public let workspaceNotFound: String
    /// `socket.workspace.reorderMany.invalidWorkspace` — shared by
    /// `workspace.reorder`, so a value neither method can read reads the same
    /// either way.
    public let invalidWorkspaceRef: String
    /// `socket.workspace.reorder.indexNotAnInteger`.
    public let reorderIndexNotAnInteger: String
    /// `socket.workspace.reorder.missingWorkspaceID`.
    public let reorderMissingWorkspaceID: String
    /// `socket.workspace.reorder.targetRequired`.
    public let reorderTargetRequired: String
    /// `socket.workspace.reorderMany.tabManagerUnavailable`.
    public let reorderManyTabManagerUnavailable: String
    /// `socket.workspace.list.tabManagerUnavailable`.
    public let tabManagerUnavailable: String
    /// The scoped denial returned when an authenticated relay owner is stale.
    public let relayOwnerUnavailable: String

    /// `socket.workspace.reorder.rejected`.
    public let reorderRejected: String

    /// Creates the localized workspace strings.
    ///
    /// - Parameters:
    ///   - reorderRejected: The refused-placement message.
    ///   - closeProtected: The `workspace.close` protected-pin message.
    ///   - closeFailed: The `workspace.close` local-teardown failure message.
    ///   - reorderManyMissingOrder: The missing-order message.
    ///   - reorderManyDuplicateWorkspace: The duplicate-workspace message.
    ///   - workspaceNotFound: The workspace-not-found message.
    ///   - invalidWorkspaceRef: The invalid-workspace message.
    ///   - reorderIndexNotAnInteger: The unreadable-`index` message.
    ///   - reorderMissingWorkspaceID: The missing-subject message.
    ///   - reorderTargetRequired: The wrong-target-count message.
    ///   - reorderManyTabManagerUnavailable: The TabManager-unavailable message.
    ///   - tabManagerUnavailable: The localized workspace-list unavailable message.
    ///   - relayOwnerUnavailable: The stale relay-owner message.
    public init(
        closeProtected: String,
        closeFailed: String,
        reorderManyMissingOrder: String,
        reorderManyDuplicateWorkspace: String,
        workspaceNotFound: String,
        invalidWorkspaceRef: String,
        reorderIndexNotAnInteger: String,
        reorderMissingWorkspaceID: String,
        reorderTargetRequired: String,
        reorderManyTabManagerUnavailable: String,
        tabManagerUnavailable: String = "TabManager not available",
        relayOwnerUnavailable: String,
        reorderRejected: String = "Workspace reorder placement was refused"
    ) {
        self.reorderRejected = reorderRejected
        self.closeProtected = closeProtected
        self.closeFailed = closeFailed
        self.reorderManyMissingOrder = reorderManyMissingOrder
        self.reorderManyDuplicateWorkspace = reorderManyDuplicateWorkspace
        self.workspaceNotFound = workspaceNotFound
        self.invalidWorkspaceRef = invalidWorkspaceRef
        self.reorderIndexNotAnInteger = reorderIndexNotAnInteger
        self.reorderMissingWorkspaceID = reorderMissingWorkspaceID
        self.reorderTargetRequired = reorderTargetRequired
        self.reorderManyTabManagerUnavailable = reorderManyTabManagerUnavailable
        self.tabManagerUnavailable = tabManagerUnavailable
        self.relayOwnerUnavailable = relayOwnerUnavailable
    }
}
