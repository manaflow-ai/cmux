import AppKit

extension SavingTextView {
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
            { [weak self] in self?.toggleFilePreviewWordWrap() }
        )]
    }

    @discardableResult
    func toggleFilePreviewWordWrap() -> Bool {
        guard let scrollView = enclosingScrollView else { return false }
        let selectedRanges = self.selectedRanges
        let previousOrigin = scrollView.contentView.bounds.origin
        let enabled = !FilePreviewWordWrapSettings.isEnabled()
        FilePreviewWordWrapSettings.setEnabled(enabled)
        applyFilePreviewWordWrap(enabled, scrollView: scrollView)
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let origin = clipView.constrainBoundsRect(
            NSRect(origin: previousOrigin, size: clipView.bounds.size)
        ).origin
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
        setSelectedRanges(selectedRanges, affinity: .downstream, stillSelecting: false)
        return true
    }
}
