public import CmuxSidebarProviderKit
public import Foundation
public import SwiftUI

/// One collapsible extension-sidebar (browser-stack) provider section.
///
/// A pure presentation composite: it renders the
/// ``ExtensionSidebarSectionHeaderRow`` followed, when expanded, by one
/// ``CmuxExtensionSidebarWorkspaceRowView`` per row. It holds no app-target
/// state and reads no `Workspace`/`TabManager`. The collapsed/in-flight flags,
/// the selected-workspace id, the per-workspace snapshot map, the resolved
/// (already localized) strings, and the disclosure animation are passed in as
/// values; the toggle/create/select/open-window intents are supplied as
/// closures. The collapse animation is applied here around ``onToggle`` so the
/// host only mutates its collapsed set inside that closure.
public struct ExtensionSidebarSectionView: View {
    let section: CmuxSidebarProviderSection
    let providerId: String
    let now: Date
    let isCollapsed: Bool
    let isWorktreeCreationInFlight: Bool
    let canCreateWorktree: Bool
    let selectedWorkspaceId: UUID?
    let workspaceSnapshotsById: [UUID: CmuxSidebarProviderWorkspace]
    let treeSectionTitle: String
    let toggleHelp: String
    let createWorktreeHelp: String
    let disclosureAnimation: Animation
    let onToggle: () -> Void
    let onCreateWorktree: () -> Void
    let onSelect: (UUID) -> Void
    let onOpenWindow: (CmuxSidebarProviderWorkspace) -> Void

    /// Creates an extension-sidebar section view.
    /// - Parameters:
    ///   - section: The rendered provider section (id/tree metadata/rows).
    ///   - providerId: The provider id the section belongs to.
    ///   - now: The reference date used to render relative timestamps in rows.
    ///   - isCollapsed: Whether the section is currently collapsed.
    ///   - isWorktreeCreationInFlight: Whether a worktree creation is running
    ///     for this section (shows a clock glyph and disables the button).
    ///   - canCreateWorktree: Whether the create-worktree button is shown.
    ///   - selectedWorkspaceId: The currently selected workspace id, if any.
    ///   - workspaceSnapshotsById: Per-workspace snapshots backing each row's
    ///     inspector, keyed by workspace id.
    ///   - treeSectionTitle: The resolved (already localized) section title.
    ///   - toggleHelp: Tooltip for the disclosure toggle.
    ///   - createWorktreeHelp: Tooltip for the create-worktree button.
    ///   - disclosureAnimation: The animation applied around the toggle intent.
    ///   - onToggle: Invoked (inside the disclosure animation) when the section
    ///     disclosure is toggled; the host mutates its collapsed set here.
    ///   - onCreateWorktree: Invoked when the create-worktree button is pressed.
    ///   - onSelect: Invoked with a workspace id when a row is tapped.
    ///   - onOpenWindow: Invoked with a workspace snapshot to open its window.
    public init(
        section: CmuxSidebarProviderSection,
        providerId: String,
        now: Date,
        isCollapsed: Bool,
        isWorktreeCreationInFlight: Bool,
        canCreateWorktree: Bool,
        selectedWorkspaceId: UUID?,
        workspaceSnapshotsById: [UUID: CmuxSidebarProviderWorkspace],
        treeSectionTitle: String,
        toggleHelp: String,
        createWorktreeHelp: String,
        disclosureAnimation: Animation,
        onToggle: @escaping () -> Void,
        onCreateWorktree: @escaping () -> Void,
        onSelect: @escaping (UUID) -> Void,
        onOpenWindow: @escaping (CmuxSidebarProviderWorkspace) -> Void
    ) {
        self.section = section
        self.providerId = providerId
        self.now = now
        self.isCollapsed = isCollapsed
        self.isWorktreeCreationInFlight = isWorktreeCreationInFlight
        self.canCreateWorktree = canCreateWorktree
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaceSnapshotsById = workspaceSnapshotsById
        self.treeSectionTitle = treeSectionTitle
        self.toggleHelp = toggleHelp
        self.createWorktreeHelp = createWorktreeHelp
        self.disclosureAnimation = disclosureAnimation
        self.onToggle = onToggle
        self.onCreateWorktree = onCreateWorktree
        self.onSelect = onSelect
        self.onOpenWindow = onOpenWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ExtensionSidebarSectionHeaderRow(
                title: treeSectionTitle,
                isCollapsed: isCollapsed,
                canCreateWorktree: canCreateWorktree,
                isWorktreeCreationInFlight: isWorktreeCreationInFlight,
                sectionAccessibilityId: section.id,
                toggleHelp: toggleHelp,
                createWorktreeHelp: createWorktreeHelp,
                onToggle: {
                    withAnimation(disclosureAnimation) {
                        onToggle()
                    }
                },
                onCreateWorktree: onCreateWorktree
            )

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(section.rows) { row in
                        CmuxExtensionSidebarWorkspaceRowView(
                            row: row,
                            workspace: workspaceSnapshotsById[row.workspaceId],
                            providerId: providerId,
                            relativeNow: now,
                            isSelected: row.workspaceId == selectedWorkspaceId,
                            onSelect: onSelect,
                            onOpenWindow: onOpenWindow
                        )
                        .id(row.id)
                        .accessibilityIdentifier("extensionSidebar.workspace.\(row.workspaceId.uuidString)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
