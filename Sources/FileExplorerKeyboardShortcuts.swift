import AppKit
import CmuxSettings
import CmuxWorkspaces

/// Perform the configured action for opening a local file from the file explorer.
@MainActor
func performFileExplorerFileOpen(path: String, onOpenFilePreview: (String) -> Void) {
    let action = FileExplorerDoubleClickActionSettings.resolvedAction()
    let hasPreferredEditor = PreferredEditorSettingsStore(defaults: .standard).resolvedCommand != nil
    switch FileExplorerDoubleClickActionSettings.fileActivation(
        action: action,
        hasPreferredEditorCommand: hasPreferredEditor
    ) {
    case .preview:
        onOpenFilePreview(path)
    case .defaultEditor:
        FileExternalOpenAction.openDefault(fileURL: URL(fileURLWithPath: path))
    case .preferredEditor:
        PreferredEditorService(defaults: .standard).open(URL(fileURLWithPath: path))
    }
}

@MainActor
extension FileExplorerPanelView.Coordinator {
    func openSelectedNode(in outlineView: NSOutlineView) {
        afterApplyingPendingFileFilter { [weak self, weak outlineView] in
            guard let self, let outlineView,
                  let row = self.resolvedSelectionRow(in: outlineView) else { return }
            self.openNode(in: outlineView, at: row)
        }
    }

    func openNodeAfterApplyingFileFilter(in outlineView: NSOutlineView, at row: Int) {
        guard row >= 0,
              let path = (outlineView.item(atRow: row) as? FileExplorerNode)?.path else { return }
        afterApplyingPendingFileFilter { [weak self, weak outlineView] in
            guard let self, let outlineView,
                  let resolvedRow = self.row(forPath: path, in: outlineView) else { return }
            self.openNode(in: outlineView, at: resolvedRow)
        }
    }

    func moveSelection(in outlineView: NSOutlineView, by delta: Int) {
        afterApplyingPendingFileFilter { [weak self, weak outlineView] in
            guard let self, let outlineView else { return }
            guard outlineView.numberOfRows > 0 else {
                self.store.select(node: nil)
                return
            }
            let currentRow = self.resolvedSelectionRow(in: outlineView)
                ?? (delta >= 0 ? -1 : outlineView.numberOfRows)
            let targetRow = min(max(currentRow + delta, 0), outlineView.numberOfRows - 1)
            self.selectRow(targetRow, in: outlineView, scroll: true)
        }
    }

    func performDisclosureAction(
        _ action: RightSidebarKeyboardNavigation.DisclosureAction,
        in outlineView: NSOutlineView
    ) {
        afterApplyingPendingFileFilter { [weak self, weak outlineView] in
            guard let self, let outlineView else { return }
            switch action {
            case .collapse:
                self.collapseSelectedItemOrMoveToParent(in: outlineView)
            case .expand:
                self.expandSelectedItemOrMoveToChild(in: outlineView)
            }
        }
    }

    func openNode(in outlineView: NSOutlineView, at row: Int) {
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? FileExplorerNode else { return }

        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else if outlineView.isExpandable(node) {
                outlineView.expandItem(node)
            }
            return
        }

        guard store.provider is LocalFileExplorerProvider else {
            onOpenFilePreview(node.path)
            return
        }
        performFileExplorerFileOpen(path: node.path, onOpenFilePreview: onOpenFilePreview)
    }

    private func afterApplyingPendingFileFilter(_ action: @escaping () -> Void) {
        guard let containerView else {
            action()
            return
        }
        containerView.applyPendingFileFilter(afterApplying: action)
    }

    private func row(forPath path: String, in outlineView: NSOutlineView) -> Int? {
        (0..<outlineView.numberOfRows).first { row in
            (outlineView.item(atRow: row) as? FileExplorerNode)?.path == path
        }
    }
}

extension FileExplorerNSOutlineView {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        guard event.isFileExplorerOpenSelectionShortcut(in: fileExplorerPanelPlacement) else { return false }
        fileExplorerCoordinator?.openSelectedNode(in: self)
        return true
    }
}

extension FileExplorerSearchResultsTableView {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        guard event.isFileExplorerOpenSelectionShortcut(in: fileExplorerPanelPlacement) else { return false }
        onCommit?()
        return true
    }
}

extension FileExplorerSearchField {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        guard !RightSidebarKeyboardNavigation.isPlainPrintableText(event) else { return false }
        guard event.isFileExplorerOpenSelectionShortcut(in: fileExplorerPanelPlacement) else { return false }
        onCommit?()
        return true
    }
}

@MainActor
extension NSEvent {
    func isFileExplorerOpenSelectionShortcut(in placement: FileExplorerPanelPlacement) -> Bool {
        isFileExplorerOpenSelectionShortcut(in: placement.openSelectionShortcutContext(for: self))
    }

    func isFileExplorerOpenSelectionShortcut(in context: ShortcutContext) -> Bool {
        KeyboardShortcutSettings.Action.fileExplorerOpenSelectionActions.contains { action in
            KeyboardShortcutSettings.shortcut(for: action).matches(event: self) &&
                KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(context)
        }
    }
}

@MainActor
private extension FileExplorerPanelPlacement {
    func openSelectionShortcutContext(for event: NSEvent) -> ShortcutContext {
        var context = AppDelegate.shared?.shortcutEventFocusContext(event).shortcutContext ??
            ShortcutFocusState(browser: false, markdown: false, sidebar: false).context
        switch self {
        case .rightSidebar, .pane:
            context.setBool(ShortcutFocusAtom.sidebarFocus.rawValue, true)
            context.setBool(ShortcutFocusAtom.browserFocus.rawValue, false)
            context.setBool(ShortcutFocusAtom.markdownFocus.rawValue, false)
            context.setBool(ShortcutFocusAtom.terminalFocus.rawValue, false)
        }
        return context
    }
}

private extension KeyboardShortcutSettings.Action {
    static var fileExplorerOpenSelectionActions: [Self] {
        [.fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias]
    }
}
