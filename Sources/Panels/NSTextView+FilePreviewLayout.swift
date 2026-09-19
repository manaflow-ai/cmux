import AppKit

extension NSTextView {
    /// Configures the text view and its scroll view for soft line wrapping
    /// (`wrap == true`) or the no-wrap baseline with a horizontal scroller
    /// (`wrap == false`). Idempotent, so it is safe to call on every SwiftUI
    /// update; toggling the `fileEditor.wordWrap` setting reflows open editors.
    func applyFilePreviewWordWrap(_ wrap: Bool, scrollView: NSScrollView) {
        guard let textContainer else { return }
        let changed = textContainer.widthTracksTextView != wrap
        let previousOrigin = scrollView.contentView.bounds.origin
        scrollView.hasHorizontalScroller = !wrap
        isHorizontallyResizable = !wrap
        if wrap {
            textContainer.widthTracksTextView = true
            // `widthTracksTextView` keeps the container pinned to the text view
            // width, so wrapping is correct even before the scroll view is laid
            // out. Only snap the frame/container to a real measured width to
            // avoid collapsing to a zero-width container during `makeNSView`,
            // before the clip view has a size; `updateNSView` re-runs once laid
            // out and reflows.
            let visibleWidth = scrollView.contentSize.width
            if visibleWidth > 0 {
                setFrameSize(NSSize(width: visibleWidth, height: frame.height))
                let containerWidth = max(0, visibleWidth - 2 * textContainerInset.width)
                if textContainer.size.width != containerWidth {
                    textContainer.size = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
                }
            }
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        guard changed else { return }
        // Reflow the existing storage. Selection, affinity, and undo history
        // remain untouched; constrain only the viewport to the new extent.
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        clipView.scroll(to: clipView.constrainBoundsRect(
            NSRect(origin: previousOrigin, size: clipView.bounds.size)
        ).origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    func applyFilePreviewTextEditorInsets() {
        let targetInset = FilePreviewTextEditorLayout.textContainerInset
        if textContainerInset.width != targetInset.width || textContainerInset.height != targetInset.height {
            textContainerInset = targetInset
        }
        if textContainer?.lineFragmentPadding != FilePreviewTextEditorLayout.lineFragmentPadding {
            textContainer?.lineFragmentPadding = FilePreviewTextEditorLayout.lineFragmentPadding
        }
    }
}

