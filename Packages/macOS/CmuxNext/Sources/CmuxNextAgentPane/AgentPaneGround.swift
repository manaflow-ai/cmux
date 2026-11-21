public import AppKit
public import CmuxNextDesign

/// The chat's own ground under its page (SPLIT NEW PANE GROUND, m81): what the page paints under its content
/// (``AgentPaneTheme/pageBackground(_:surface:backgrounds:)``, the user's `appearance.surfaces` background), drawn by the
/// pane from the turn it is made. Chrome shows a new tab's background at once and its content later; a chat here showed
/// the window's color until its page drew (a split's New Tab spare held away or clear until its next frame, a new page
/// under its loading cover: 4 to 10 frames at 120 Hz, both engines). Only an opaque ground paints: the page paints the
/// same color over it at rest, so nothing changes once it drew, and a translucent one is not painted twice. It covers
/// where the page draws less the row the chat shares with its pane's tabs (no backing behind the tabs, Leo 2026-11-03),
/// takes no clicks, and is the bottom view of the pane.
final class AgentPaneGround: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Puts the ground under everything `pane` shows.
    func install(in pane: NSView) {
        pane.addSubview(self, positioned: .below, relativeTo: nil)
    }

    /// Paints `color` when it is opaque, else nothing (the window's sheet shows, as before).
    func paint(_ color: ThemeRGB) {
        let ground = PageImageBackground.isOpaque(color) ? color.cgColor : nil
        if layer?.backgroundColor != ground { layer?.backgroundColor = ground }
    }

    /// Lays the ground in `content` (where the page draws, in `pane`) less the top of `pane` its shared tab row covers.
    func place(in content: NSRect, of pane: NSView) {
        var frame = content
        let cover = pane.tabRowCoverHeight
        if cover > 0 {
            if pane.isFlipped {
                let top = max(frame.minY, pane.bounds.minY + cover)
                frame = NSRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top))
            } else {
                frame.size.height = max(0, min(frame.maxY, pane.bounds.maxY - cover) - frame.minY)
            }
        }
        if self.frame != frame { self.frame = frame }
    }
}

extension AgentPaneView {
    /// A picture of this chat stands in under this view (its pane's launch image, the chat's last frame): the pane stays
    /// clear above it. The loading state is off, and the ground, which lies over that picture, stays out until the
    /// picture goes (``pictureBelowWent()``) or the page paints.
    public func standOverPicture() {
        showsLoadingState = false
        ground.isHidden = true
    }

    /// The picture under this view went: the ground paints again, and a chat that has not painted shows its loading
    /// state (a New Tab page has none).
    public func pictureBelowWent() {
        ground.isHidden = false
        if model.newTab == nil { showsLoadingState = true }
    }
}

/// SPLIT OPEN CHAT: the chat's ground is this pane's ground. Its pane shows it where the chat, held at its rest size
/// on a split's spring, does not reach yet (`PaneClipView.showHeldGround`), and when the pane closes. Nil under a
/// picture of the chat and for a translucent ground: the pane then shows what it showed before.
extension AgentPaneView: PaneGroundReporting {
    public var paneGround: CGColor? { ground.isHidden ? nil : ground.layer?.backgroundColor }
}
