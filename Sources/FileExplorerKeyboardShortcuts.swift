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
        guard let row = resolvedSelectionRow(in: outlineView) else { return }
        openNode(in: outlineView, at: row)
    }

    func openNode(in outlineView: NSOutlineView, at row: Int) {
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? FileExplorerNode,
              node.resourceContextID == nil || node.resourceContextID == store.resourceContextID else { return }

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
}

extension FileExplorerNSOutlineView {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        guard event.isFileExplorerOpenSelectionShortcut(in: fileExplorerPanelPlacement) else { return false }
        endQuickSearch()
        fileExplorerCoordinator?.openSelectedNode(in: self)
        return true
    }

    /// Finder actions bound in Settings: Quick Look, Rename, Show Hidden
    /// Files and Enclosing Folder, plus Command-Delete for Move to Trash.
    func handleFinderActionShortcut(_ event: NSEvent) -> Bool {
        guard let coordinator = fileExplorerCoordinator else { return false }
        if event.isFileExplorerMoveToTrashKey {
            endQuickSearch()
            coordinator.moveToTrash(coordinator.selectedNodes(in: self))
            return true
        }
        guard let action = event.fileExplorerFinderAction(in: fileExplorerPanelPlacement) else { return false }
        endQuickSearch()
        switch action {
        case .fileExplorerQuickLook:
            toggleQuickLook()
        case .fileExplorerRenameSelection:
            if let node = coordinator.selectedNodes(in: self).first {
                coordinator.beginRenaming(node)
            }
        case .fileExplorerToggleHiddenFiles:
            coordinator.toggleHiddenFiles(nil)
        case .fileExplorerSelectParent:
            coordinator.selectParentOfSelection(in: self)
        default:
            return false
        }
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
        guard type == .keyDown else { return false }
        return isFileExplorerOpenSelectionShortcut(in: placement.openSelectionShortcutContext(for: self))
    }

    func isFileExplorerOpenSelectionShortcut(in context: ShortcutContext) -> Bool {
        KeyboardShortcutSettings.Action.fileExplorerOpenSelectionActions.contains { action in
            KeyboardShortcutSettings.shortcut(for: action).matches(event: self) &&
                KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(context)
        }
    }

    /// The Settings-backed Finder action this key event triggers in the tree.
    func fileExplorerFinderAction(in placement: FileExplorerPanelPlacement) -> KeyboardShortcutSettings.Action? {
        guard type == .keyDown else { return nil }
        let context = placement.openSelectionShortcutContext(for: self)
        return KeyboardShortcutSettings.Action.fileExplorerFinderActions.first { action in
            KeyboardShortcutSettings.shortcut(for: action).matches(event: self) &&
                KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(context)
        }
    }

    /// Command-Delete, Finder's Move to Trash. Delete has no representation
    /// in the shortcut recorder, so this standard editing key stays fixed.
    var isFileExplorerMoveToTrashKey: Bool {
        guard type == .keyDown, keyCode == 51 || keyCode == 117 else { return false }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        return flags == .command
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

extension KeyboardShortcutSettings.Action {
    static var fileExplorerOpenSelectionActions: [Self] {
        [.fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias]
    }

    /// Tree actions matched inside the Files outline, in match priority order.
    static var fileExplorerFinderActions: [Self] {
        [.fileExplorerQuickLook, .fileExplorerRenameSelection, .fileExplorerToggleHiddenFiles, .fileExplorerSelectParent]
    }
}
