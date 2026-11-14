import AppKit

extension SavingTextView {
    /// Joins save and zoom in the editor’s existing chord dispatcher.
    func filePreviewWordWrapShortcutCandidates() -> [
        (shortcut: StoredShortcut, isAllowed: (NSEvent) -> Bool, perform: () -> Void)
    ] {
        return KeyboardShortcutSettings.shortcutBindings(for: .toggleFileEditorWordWrap).compactMap { binding in
            guard !binding.shortcut.isUnbound else { return nil }
            return (
                binding.shortcut,
                { [weak self] event in
                    guard let self else { return false }
                    if window != nil, let appDelegate = AppDelegate.shared {
                        return binding.whenClause.evaluate(
                            appDelegate.shortcutWhenClauseContext(
                                for: .toggleFileEditorWordWrap,
                                clause: binding.whenClause,
                                event: event
                            )
                        )
                    }
                    return binding.whenClause.evaluate(Self.filePreviewTextEditorShortcutContext)
                },
                { [weak self] in _ = self?.toggleFilePreviewWordWrap() }
            )
        }
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
