import AppKit

/// One inline-rename editing session for a pure-AppKit sidebar workspace row.
///
/// Reuses the SwiftUI sidebar's rename engine so both sidebars share a single
/// behavior path: `SidebarInlineRenameTextField` takes focus and selects the
/// whole title when it enters the window (no re-entrant `selectText(_:)`
/// that would restart the field-editor session and instantly commit the
/// untouched title — issue #9495), `SidebarInlineRenameCoordinator` resolves
/// Enter, double-Escape, and focus loss at most once and passes IME
/// composition through, and `SidebarInlineRenameCommit` decides whether the
/// draft becomes a `customTitle` write. An unchanged title on a workspace
/// without a user-owned custom title resolves to no write, so a stray commit
/// can never freeze auto-naming.
@MainActor
final class SidebarRowInlineRenameSession {
    /// The field hosted in the row while the session is active; it focuses
    /// itself and selects the whole title when the row adds it to a
    /// window-attached hierarchy.
    let field: SidebarInlineRenameTextField

    private let coordinator: SidebarInlineRenameCoordinator
    private let baselineTitle: String
    private let baselineHadUserCustomTitle: Bool
    private let onResolve: @MainActor (String?) -> Void
    private var isResolved = false

    /// Creates a session seeded with the row's current title.
    ///
    /// - Parameters:
    ///   - baselineTitle: The title shown when editing begins; also the
    ///     baseline for the unchanged-title no-op rule.
    ///   - baselineHadUserCustomTitle: Whether the workspace already had a
    ///     user-owned custom title when editing began.
    ///   - onResolve: Runs exactly once with the title to persist, or `nil`
    ///     when the rename cancels or resolves to no write. The receiver
    ///     owns tearing the session's field down.
    init(
        baselineTitle: String,
        baselineHadUserCustomTitle: Bool,
        onResolve: @escaping @MainActor (String?) -> Void
    ) {
        self.baselineTitle = baselineTitle
        self.baselineHadUserCustomTitle = baselineHadUserCustomTitle
        self.onResolve = onResolve
        field = SidebarInlineRenameTextField(string: baselineTitle)
        coordinator = SidebarInlineRenameCoordinator(onCommit: { _ in }, onCancel: {})
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = String(
            localized: "commandPalette.rename.workspacePlaceholder",
            defaultValue: "Workspace name"
        )
        field.setAccessibilityLabel(String(
            localized: "sidebar.workspace.rename.field.accessibilityLabel",
            defaultValue: "Rename workspace"
        ))
        coordinator.onCommit = { [weak self] draft in self?.resolve(draft: draft) }
        coordinator.onCancel = { [weak self] in self?.resolveAsCancel() }
        field.delegate = coordinator
    }

    /// Resolves the session for a suspension teardown, returning the title
    /// to persist (`nil` means nothing to write). The caller owns deferring
    /// the write past the table mutation, so this never invokes `onResolve`;
    /// the resolved state also neutralizes any field-editor end-editing that
    /// fires while the field leaves the hierarchy.
    func resolveForSuspension() -> String? {
        guard !isResolved else { return nil }
        isResolved = true
        let draft = field.currentEditor()?.string ?? field.stringValue
        return titleToCommit(draft: draft)
    }

    private func resolve(draft: String) {
        guard !isResolved else { return }
        isResolved = true
        onResolve(titleToCommit(draft: draft))
    }

    private func resolveAsCancel() {
        guard !isResolved else { return }
        isResolved = true
        onResolve(nil)
    }

    private func titleToCommit(draft: String) -> String? {
        SidebarInlineRenameCommit().titleToCommit(
            draft: draft,
            baseline: baselineTitle,
            baselineHadUserCustomTitle: baselineHadUserCustomTitle
        )
    }
}
