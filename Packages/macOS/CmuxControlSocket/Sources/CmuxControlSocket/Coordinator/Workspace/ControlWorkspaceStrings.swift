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
    /// `socket.workspace.reorderMany.workspaceNotFound`.
    public let reorderManyWorkspaceNotFound: String
    /// `socket.workspace.reorderMany.invalidWorkspace`.
    public let reorderManyInvalidWorkspace: String
    /// `socket.workspace.reorderMany.tabManagerUnavailable`.
    public let reorderManyTabManagerUnavailable: String

    /// Creates the localized workspace strings.
    ///
    /// - Parameters:
    ///   - closeProtected: The `workspace.close` protected-pin message.
    ///   - closeFailed: The `workspace.close` local-teardown failure message.
    ///   - reorderManyMissingOrder: The missing-order message.
    ///   - reorderManyDuplicateWorkspace: The duplicate-workspace message.
    ///   - reorderManyWorkspaceNotFound: The workspace-not-found message.
    ///   - reorderManyInvalidWorkspace: The invalid-workspace message.
    ///   - reorderManyTabManagerUnavailable: The TabManager-unavailable message.
    public init(
        closeProtected: String,
        closeFailed: String,
        reorderManyMissingOrder: String,
        reorderManyDuplicateWorkspace: String,
        reorderManyWorkspaceNotFound: String,
        reorderManyInvalidWorkspace: String,
        reorderManyTabManagerUnavailable: String
    ) {
        self.closeProtected = closeProtected
        self.closeFailed = closeFailed
        self.reorderManyMissingOrder = reorderManyMissingOrder
        self.reorderManyDuplicateWorkspace = reorderManyDuplicateWorkspace
        self.reorderManyWorkspaceNotFound = reorderManyWorkspaceNotFound
        self.reorderManyInvalidWorkspace = reorderManyInvalidWorkspace
        self.reorderManyTabManagerUnavailable = reorderManyTabManagerUnavailable
    }
}
