public import SwiftUI

/// The header row above an extension-sidebar (browser-stack) section.
///
/// Renders the folder disclosure toggle, the section title, and an optional
/// create-worktree button. The view is a pure presentation leaf: it holds no
/// app-target state and performs no work itself. The disclosure state, the
/// localized strings, and the worktree-creation availability/in-flight flags
/// are passed in as values, and the two actions are supplied as closures. The
/// collapse animation lives at the call site (it mutates the host's collapsed
/// set), so this row only forwards the toggle intent through ``onToggle``.
public struct ExtensionSidebarSectionHeaderRow: View {
    let title: String
    let isCollapsed: Bool
    let canCreateWorktree: Bool
    let isWorktreeCreationInFlight: Bool
    let sectionAccessibilityId: String
    let toggleHelp: String
    let createWorktreeHelp: String
    let onToggle: () -> Void
    let onCreateWorktree: () -> Void

    /// Creates an extension-sidebar section header row.
    /// - Parameters:
    ///   - title: The resolved (already localized) section title.
    ///   - isCollapsed: Whether the section is currently collapsed.
    ///   - canCreateWorktree: Whether the create-worktree button is shown.
    ///   - isWorktreeCreationInFlight: Whether a worktree creation is running
    ///     for this section (shows a clock glyph and disables the button).
    ///   - sectionAccessibilityId: The section id suffix used to build the
    ///     create-worktree button's accessibility identifier.
    ///   - toggleHelp: Tooltip for the disclosure toggle.
    ///   - createWorktreeHelp: Tooltip for the create-worktree button.
    ///   - onToggle: Invoked when the disclosure toggle is pressed.
    ///   - onCreateWorktree: Invoked when the create-worktree button is pressed.
    public init(
        title: String,
        isCollapsed: Bool,
        canCreateWorktree: Bool,
        isWorktreeCreationInFlight: Bool,
        sectionAccessibilityId: String,
        toggleHelp: String,
        createWorktreeHelp: String,
        onToggle: @escaping () -> Void,
        onCreateWorktree: @escaping () -> Void
    ) {
        self.title = title
        self.isCollapsed = isCollapsed
        self.canCreateWorktree = canCreateWorktree
        self.isWorktreeCreationInFlight = isWorktreeCreationInFlight
        self.sectionAccessibilityId = sectionAccessibilityId
        self.toggleHelp = toggleHelp
        self.createWorktreeHelp = createWorktreeHelp
        self.onToggle = onToggle
        self.onCreateWorktree = onCreateWorktree
    }

    public var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggle) {
                Image(systemName: isCollapsed ? "folder" : "folder.fill")
                    .font(.system(size: 13, weight: .regular))
                    .offset(y: -0.5)
            }
            .buttonStyle(.plain)
            .safeHelp(toggleHelp)

            Text(title)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if canCreateWorktree {
                Button(action: onCreateWorktree) {
                    Image(systemName: isWorktreeCreationInFlight ? "clock" : "plus")
                        .font(.system(size: 11, weight: .regular))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(isWorktreeCreationInFlight)
                .safeHelp(createWorktreeHelp)
                .accessibilityIdentifier("ExtensionSidebarCreateWorktreeButton.\(sectionAccessibilityId)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}
