public import AppKit
import CmuxNextDesign

/// The Chief Settings card as a popover under the header's name pill: a
/// popup of the shared native host (`NativePopupHost`), a borderless child
/// panel of the window on the overlay glass (`Glass.makeOverlayPanel`), in the
/// theme of the Home it opens from. It never covers the header: it opens
/// below the pill (above it when the screen has no room), centered on it as an
/// `NSPopover` is (Leo 2026-10-20: it hung off the pill's leading edge, over the
/// transcript), and it closes on a click outside, Escape, the pill again, or
/// the window moving away.
@MainActor
public final class HomeChiefSettingsPopover {
    public let content: HomeChiefSettingsView
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.home.chiefSettings"))
    private let card: OverlaySurfaceView
    private weak var anchor: NSView?

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
            self?.content.commitEditing()
            self?.content.cardClosed()
        }
        content.onResize = { [weak self] in self?.resize() }
        // The open panel takes the keys from the popover, which closes; it runs over the window.
        content.pictureWindow = { [weak self] in self?.anchor?.window }
    }

    /// The popover is on screen and not closing.
    public var isShown: Bool { popup.isShown }

    /// The window whose Home answers `home.toggleChiefSettings` now: see ``toggleTarget(key:ordered:)``.
    public static var frontToggleTarget: NSWindow? { toggleTarget(key: NSApp.keyWindow, ordered: NSApp.orderedWindows) }

    /// The window whose Home answers `home.toggleChiefSettings`: the key window, else the frontmost
    /// visible one (`ordered` front to back; a CLI run while another app is in front), else none.
    /// A child window stands for the window it belongs to: a child panel with the keys (this
    /// popover itself, a feed or composer popup), so a second toggle closes the popover it opened,
    /// and with no key window a child listed first (Chromium's page window: outside an active app
    /// AppKit lists it before its parent, and a capture slot is never active).
    public static func toggleTarget(key: NSWindow?, ordered: [NSWindow]) -> NSWindow? {
        guard var window = key ?? ordered.first(where: { $0.isVisible }) else { return nil }
        while let parent = window.parent { window = parent }
        return window
    }

    /// Whether the Home in `window` answers a toggle posted for `target` (``toggleTarget(key:ordered:)``'s
    /// window): only that window's, and none when no window was in front.
    public static func answersToggle(for target: ObjectIdentifier?, in window: NSWindow?) -> Bool {
        guard let target, let window else { return false }
        return target == ObjectIdentifier(window)
    }

    /// Opens the card under `anchor` (the name pill), in its theme. A press on
    /// one of `toggles` (the pill, the header avatar) closes it through the
    /// toggle, not the click monitor, so that press never reopens it. Returns
    /// false when it cannot show (no visible window).
    @discardableResult
    public func show(relativeTo anchor: NSView, toggles: [NSView]) -> Bool {
        guard let window = anchor.window else { return false }
        self.anchor = anchor
        popup.panel.adoptThemeScope(of: anchor)
        card.applyTheme()
        let toggles = toggles.map { WeakView(view: $0) }
        popup.keepsOpen = { event in
            toggles.contains { toggle in
                guard let view = toggle.view, !view.isHiddenOrHasHiddenAncestor, event.window === view.window else { return false }
                return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            }
        }
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        guard popup.show(size: size(), anchor: rect, in: window, preferred: .below, centered: true, makeKey: true) != nil else { return false }
        // Like an NSPopover opened by a click: keys reach the card (Tab enters it, Escape closes
        // it), but no control shows a focus ring until the keyboard moves there. A ring on the
        // picture drew while open and vanished on the close's first frame (recording 2026-10-20).
        popup.panel.makeFirstResponder(nil)
        return true
    }

    /// Closes the card (fading toward the pill), keeping a name being edited.
    public func close() {
        content.commitEditing()
        content.cardClosed()
        popup.hide()
    }

    /// The content's height changed: the card follows it while shown.
    private func resize() {
        guard popup.isShown, let anchor, let window = anchor.window else { return }
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        popup.show(size: size(), anchor: rect, in: window, preferred: .below, centered: true, makeKey: popup.panel.isKeyWindow)
    }

    /// The card's frame on screen while shown (tests).
    var cardFrame: CGRect { popup.cardFrame }

    /// The card's size: the settings' fixed width and the height of what shows.
    private func size() -> CGSize {
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        return CGSize(width: HomeChiefSettingsView.width, height: ceil(fitting.height))
    }
}

/// A view the popover's click rule reads without keeping it alive.
private struct WeakView {
    weak var view: NSView?
}
