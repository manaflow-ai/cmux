import AppKit

extension SavingTextView {
    /// Joins save and zoom in the editor’s existing chord dispatcher.
    func filePreviewWordWrapShortcutCandidates() -> [
        (shortcut: StoredShortcut, isAllowed: (NSEvent) -> Bool, perform: () -> Void)
    ] {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleFileEditorWordWrap)
        guard !shortcut.isUnbound else { return [] }
        return [(
            shortcut,
            { [weak self] event in
                guard let self else { return false }
                if window != nil, let appDelegate = AppDelegate.shared {
                    return appDelegate.shortcutWhenClauseAllows(action: .toggleFileEditorWordWrap, event: event)
                }
                return KeyboardShortcutSettings.effectiveWhenClause(for: .toggleFileEditorWordWrap)
                    .evaluate(Self.filePreviewTextEditorShortcutContext)
            },
            { [weak self] in _ = self?.toggleFilePreviewWordWrap() }
        )]
    }

    /// Changes the shared preference and immediately reflows this editor in place.
    @discardableResult
    func toggleFilePreviewWordWrap() -> Bool {
        wordWrapSettings.setEnabled(!wordWrapSettings.isEnabled())
        if let scrollView = enclosingScrollView {
            applyFilePreviewWordWrap(wordWrapSettings.isEnabled(), scrollView: scrollView)
        }
        return true
    }
}
