public import AppKit

/// A card that asks the person for the Chief, inline in its conversation (a cookie import's
/// permission card, `CookieImportCardView`): above the field and the notice, centered and no
/// wider than ``askMaximumWidth``, over the newest messages until it is answered and closed.
extension HomeNativeTranscriptView {
    /// The widest the ask card is laid out.
    public static let askMaximumWidth: CGFloat = 560

    /// Shows `view` as the conversation's ask card (nil removes it); `height` gives its height for a width.
    public func setAsk(_ view: NSView?, height: ((CGFloat) -> CGFloat)?) {
        guard view !== askView else {
            needsLayout = true
            return
        }
        askView?.removeFromSuperview()
        askView = view
        askHeight = view == nil ? nil : height
        if let view { addSubview(view, positioned: .above, relativeTo: nil) }
        needsLayout = true
    }

    /// The ask card on screen, nil when none.
    public var currentAsk: NSView? { askView }

    /// Above the notice when one shows, else above the field.
    func layoutAsk() {
        guard let askView, let askHeight else { return }
        let width = min(Self.askMaximumWidth, max(0, bounds.width - 32))
        let height = askHeight(width)
        let bottom = notice != nil ? noticeLabel.frame.minY : transcript.fieldTop
        let frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: max(transcript.headerHeight, bottom - height - 8), width: width, height: height)
        if askView.frame != frame { askView.frame = frame }
    }
}
