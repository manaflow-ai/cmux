public import AppKit

/// A section pinned at the top of the chat, under the header (Chief Home's Needs you): it stays
/// in place while the messages scroll under it. It lies over the transcript, so showing it,
/// hiding it or a change of its height moves no message (no layout shift); the host decides what
/// it shows and when (nil: none).
extension HomeNativeTranscriptView {
    /// The pinned section shown now (tests and `debug.home`).
    public var pinnedSection: NSView? { pinned?.view }

    /// Shows `view` pinned under the header, measured once now (its fitting height); nil removes it.
    public func setPinnedSection(_ view: NSView?) {
        guard view !== pinned?.view else { return pinnedSectionDidResize() }
        pinned?.view.removeFromSuperview()
        pinned = nil
        if let view {
            // Over the transcript and the first-run panel, under the notice above the field.
            addSubview(view, positioned: .below, relativeTo: noticeLabel)
            pinned = (view, 0)
            pinnedSectionDidResize()
        } else {
            needsLayout = true
        }
    }

    /// The pinned section's content changed height (a request came or went): measure it again.
    public func pinnedSectionDidResize() {
        guard let view = pinned?.view else { return }
        let height = ceil(view.fittingSize.height)
        guard height != pinned?.height || view.frame.isEmpty else { return }
        pinned = (view, height)
        needsLayout = true
        layoutPinnedSection()
    }

    /// Under the header, inset from the sides like the field, no wider than a reading column; never
    /// over the message box.
    func layoutPinnedSection() {
        guard let pinned else { return }
        let (view, height) = pinned
        let inset: CGFloat = 12
        let width = min(max(0, bounds.width - 2 * inset), Self.pinnedSectionMaxWidth)
        let top = transcript.headerHeight + 4
        let shown = min(height, max(0, transcript.fieldTop - top - 8))
        let frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: top, width: width, height: shown)
        if view.frame != frame { view.frame = frame }
    }

    /// The pinned section's widest.
    static let pinnedSectionMaxWidth: CGFloat = 640
}
