public import AppKit
import CmuxNextDesign

/// The Chief Settings card as a popover under the header's name pill: a
/// popup of the shared native host (`NativePopupHost`), a borderless child
/// panel of the window on the overlay glass (`Glass.makeOverlayPanel`), in the
/// theme of the Home it opens from. It never covers the header: it opens
/// below the pill (above it when the screen has no room), and it closes on a
/// click outside, Escape, the pill again, or the window moving away.
@MainActor
public final class HomeChiefSettingsPopover {
    public let content: HomeChiefSettingsView
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.home.chiefSettings"))
    private let card: OverlaySurfaceView
    private weak var anchor: NSView?
    /// The timestamp of the event that last dismissed the card.
    private var dismissStamp: TimeInterval?

    public init(content: HomeChiefSettingsView) {
        self.content = content
        let body = NSView()
        body.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            content.topAnchor.constraint(equalTo: body.topAnchor),
        ])
        card = Glass.makeOverlayPanel(content: body, cornerRadius: PopupStyle.standard.cornerRadius)
        popup.panel.adoptPopupStyle(card: card)
        popup.onDismiss = { [weak self] in
            self?.dismissStamp = NSApp.currentEvent?.timestamp
            self?.content.commitEditing()
        }
        content.onResize = { [weak self] in self?.resize() }
        // The open panel takes the keys from the popover, which closes; it runs over the window.
        content.pictureWindow = { [weak self] in self?.anchor?.window }
    }

    /// The popover is on screen and not closing.
    public var isShown: Bool { popup.isShown }

    /// The event being handled is the press that just dismissed the card (a
    /// click on the header avatar, which also toggles it): it must not reopen it.
    public var closedByCurrentEvent: Bool {
        guard let dismissStamp, let now = NSApp.currentEvent?.timestamp else { return false }
        return now == dismissStamp
    }

    /// Opens the card under `anchor` (the name pill), in its theme. Returns
    /// false when it cannot show (no visible window).
    @discardableResult
    public func show(relativeTo anchor: NSView) -> Bool {
        guard let window = anchor.window else { return false }
        self.anchor = anchor
        popup.panel.adoptThemeScope(of: anchor)
        card.applyTheme()
        // A press on the pill toggles the card: the pill closes it, not the click monitor.
        popup.keepsOpen = { [weak anchor] event in
            guard let anchor, event.window === anchor.window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        return popup.show(size: size(), anchor: rect, in: window, preferred: .below, makeKey: true) != nil
    }

    /// Closes the card (fading toward the pill), keeping a name being edited.
    public func close() {
        content.commitEditing()
        popup.hide()
    }

    /// The content's height changed: the card follows it while shown.
    private func resize() {
        guard popup.isShown, let anchor, let window = anchor.window else { return }
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        popup.show(size: size(), anchor: rect, in: window, preferred: .below, makeKey: popup.panel.isKeyWindow)
    }

    /// The card's size: the settings' fixed width and the height of what shows.
    private func size() -> CGSize {
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        return CGSize(width: HomeChiefSettingsView.width, height: ceil(fitting.height))
    }
}
