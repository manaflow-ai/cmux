public import Foundation

/// Computes the pure close-planning half of the window's workspace-close
/// flows over the window's `WorkspacesModel`: which workspaces are closable in
/// sidebar order, the sidebar-selected subset in sidebar order, and the
/// confirmation `WorkspaceClosePlan` (title/message/acceptCmdD). The plan is a
/// pure function of the model snapshot plus the localized strings the app
/// supplies through ``CloseConfirming``.
///
/// The apply half — `Workspace` teardown, `AppDelegate`/window-close routing,
/// remote-tmux kill marking, and the `NSAlert` presentation itself — stays in
/// the window-side `TabManager`, which owns those god/AppKit collaborators.
/// This split lifts the legacy `orderedClosableWorkspaces`,
/// `orderedSidebarSelectedWorkspaceIds`, `closeWorkspacesPlan(for:)`, and
/// `closeWorkspaceDisplayTitle` bodies out of the god file one-for-one and
/// makes the close sequence machine-diffable and unit-testable.
@MainActor
public final class WorkspaceCloseCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private weak var confirming: (any CloseConfirming)?

    /// Creates the coordinator over the window's workspace model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// Attaches the window-side confirmation seam (the localized-string and
    /// alert-presenting half the app target owns).
    public func attach(confirming: any CloseConfirming) {
        self.confirming = confirming
    }

    /// The workspaces matching `workspaceIds`, returned in the model's sidebar
    /// order and filtered to those actually closable (pinned excluded unless
    /// `allowPinned`). Legacy `orderedClosableWorkspaces(_:allowPinned:)`.
    public func orderedClosableWorkspaces(_ workspaceIds: [UUID], allowPinned: Bool) -> [Tab] {
        let targetIds = Set(workspaceIds)
        return model.tabs.compactMap { workspace in
            guard targetIds.contains(workspace.id) else { return nil }
            guard allowPinned || !workspace.isPinned else { return nil }
            return workspace
        }
    }

    /// The intersection of `sidebarSelectedWorkspaceIds` with the window's
    /// workspaces, returned in sidebar order. Legacy
    /// `orderedSidebarSelectedWorkspaceIds()`.
    public func orderedSidebarSelectedWorkspaceIds(
        sidebarSelectedWorkspaceIds: Set<UUID>
    ) -> [UUID] {
        model.tabs.compactMap { workspace in
            sidebarSelectedWorkspaceIds.contains(workspace.id) ? workspace.id : nil
        }
    }

    /// Builds the confirmation plan for closing `workspaces`. Pure assembly of
    /// the legacy `closeWorkspacesPlan(for:)`: the title/message come from the
    /// app's localized catalog (through ``CloseConfirming``), and `acceptCmdD`
    /// / `willCloseWindow` is true exactly when the batch closes every
    /// workspace in the window.
    ///
    /// Returns `nil` only when the confirmation seam has not been attached; the
    /// window-side caller never reaches planning before wiring it.
    public func closeWorkspacesPlan(for workspaces: [Tab]) -> WorkspaceClosePlan? {
        guard let confirming else { return nil }
        let willCloseWindow = workspaces.count == model.tabs.count
        let title = confirming.closeWorkspacesTitle(willCloseWindow: willCloseWindow)
        let bulletedTitles = workspaces
            .map { "• \(closeWorkspaceDisplayTitle($0.title))" }
            .joined(separator: "\n")
        let message = confirming.closeWorkspacesMessage(
            willCloseWindow: willCloseWindow,
            workspaceCount: workspaces.count,
            bulletedTitles: bulletedTitles
        )
        return WorkspaceClosePlan(
            workspaceIds: workspaces.map(\.id),
            willCloseWindow: willCloseWindow,
            title: title,
            message: message,
            acceptCmdD: willCloseWindow
        )
    }

    /// Collapses a workspace title to a single confirmation-list line, falling
    /// back to the localized "Workspace" name when empty. Legacy
    /// `closeWorkspaceDisplayTitle(_:)`.
    public func closeWorkspaceDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return confirming?.workspaceDisplayTitleFallback ?? ""
    }
}
