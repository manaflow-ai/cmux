public import AppKit

/// The one native host for the popups that open from the omnibar and the toolbar (Lawrence
/// 2026-10-14: "omnibar stuff should be macos specific so it feels more native"; hq
/// `.cmux-scratch/omnibar-popups/REUSE.md`). A popup is a borderless child panel of its window in
/// the popup style (``NSPanel/adoptPopupStyle(card:)``), so it draws above Chromium page windows
/// and moves with the window. The host owns what every popup shares:
///
/// - placement: below the anchor or above it on the screen (``PopupPlacement``);
/// - motion: opens in one frame and shrinks back toward the anchor on close
///   (``NSWindow/openPopup(pivot:)``);
/// - dismiss rules: a click outside the popup (``keepsOpen`` lists the clicks that do not count),
///   Escape in the popup, the app going inactive, the window moving, resizing, closing or
///   minimizing, and for a ``NativePopupPanel`` the popup losing the keys.
///
/// The content (native rows, controls, SwiftUI) is the owner's.
@MainActor
public final class NativePopupHost {
    public let panel: NSPanel
    /// A click outside the popup that leaves it open (the page that owns a menu, the control
    /// that toggles the popup).
    public var keepsOpen: (NSEvent) -> Bool = { _ in false }
    /// The popup closed by a dismiss rule; ``hide()`` does not call it.
    public var onDismiss: (() -> Void)?
    /// The control the popup opened from (screen), which it closes toward.
    public private(set) var anchor: CGRect = .zero
    /// Fading out after a hide: gone for the owner and for tests.
    public private(set) var isClosing = false
    /// Bumped by every show and hide: a close whose fade ends after a new show keeps the panel.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []

    public init(panel: NSPanel) {
        self.panel = panel
        if let keyed = panel as? NativePopupPanel {
            keyed.onLostKeys = { [weak self, weak keyed] elsewhere in
                guard let self, let keyed else { return }
                // A press on the control that toggles the popup makes its window key first; the
                // control closes the popup itself, so that key loss is not a dismiss.
                let press = NSApp.currentEvent.flatMap { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) ? $0 : nil }
                if let press, press.window !== keyed, keepsOpen(press) { return }
                // Shown without the keys, a window of the app took them without a press (Cmd-Tab
                // into the app, a focus request): the popup takes them over, as a popup shown with
                // the app active has them; it never takes them while the app is inactive
                // (ActiveAppKeyPanel). A press elsewhere closes it through the click monitor.
                if elsewhere, press == nil, isShown {
                    keyed.makeKey()
                    return
                }
                dismiss()
            }
        }
    }

    /// The popup is on screen and not closing.
    public var isShown: Bool { panel.isVisible && !isClosing }

    /// The card's frame (screen), without the shadow band.
    public var cardFrame: CGRect { PopupStyle.standard.cardFrame(inWindow: panel.frame) }

    /// Shows (or moves) the popup with a card of `size` at `anchor` (screen) over `window`.
    /// `trailing` and `centered` align it on the anchor (``PopupPlacement/frame(anchor:size:preferred:trailing:centered:screen:gap:margin:)``).
    /// `makeKey` gives it the keys (a ``NativePopupPanel`` takes them only while the app is
    /// active). The popup shows in one frame, with no grow or fade in; its close still fades.
    /// Returns the card frame and the side it took, or nil when it cannot show.
    @discardableResult
    public func show(size: CGSize, anchor: CGRect, in window: NSWindow, preferred: PopupPlacement.Side = .below,
                     trailing: Bool = false, centered: Bool = false, makeKey: Bool = false) -> (frame: CGRect, side: PopupPlacement.Side)? {
        guard window.isVisible, let screen = PopupPlacement.screen(for: anchor, fallback: window) else { return nil }
        let (frame, side) = PopupPlacement.frame(anchor: anchor, size: size, preferred: preferred, trailing: trailing,
                                                 centered: centered, screen: screen.visibleFrame)
        generation += 1
        // A fresh open, or a reopen during the close (whose fade runs on the card, not the alpha).
        let opening = !panel.isVisible || isClosing
        isClosing = false
        self.anchor = anchor
        panel.setFrame(PopupStyle.standard.windowFrame(forCard: frame), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.level = window.level
        // Opens like every native popup (no flash); a popup already open stays put.
        if opening, !panel.isVisible { panel.alphaValue = 0 }
        if makeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
        if opening { panel.openPopup(pivot: panel.popupPivot(toward: anchor)) }
        watch(window)
        return (frame, side)
    }

    /// Closes the popup (fading toward its anchor) without calling ``onDismiss``.
    public func hide() {
        unwatch()
        guard panel.isVisible, !isClosing else { return }
        generation += 1
        isClosing = true
        let closing = generation
        let panel = panel
        // A closing popup gives the keys back at once: typing during the fade goes to the window.
        if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            if let parent = panel.parent, parent.isVisible { parent.makeKey() }
        }
        // The panel leaves even when its owner goes during the fade (its tab closed).
        panel.closePopup(pivot: panel.popupPivot(toward: anchor)) { [weak self] in
            // A show during the close keeps the panel.
            guard (self?.generation ?? closing) == closing else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.resetPopupScale()
            self?.isClosing = false
        }
    }

    /// Closes the popup by a dismiss rule: ``hide()``, then ``onDismiss``.
    public func dismiss() {
        guard isShown else { return unwatch() }
        hide()
        onDismiss?()
    }

    private func watch(_ window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [(NSNotification.Name, AnyObject?)] = [
            (NSApplication.didResignActiveNotification, nil), (NSWindow.willMoveNotification, window),
            (NSWindow.didResizeNotification, window), (NSWindow.willCloseNotification, window),
            (NSWindow.didMiniaturizeNotification, window),
        ]
        observers = names.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window !== self.panel, !self.keepsOpen(event) else { return event }
            self.dismiss()
            return event
        }
        // Escape in the popup closes it (a text field in it would otherwise take it as cancel).
        let escape = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 53, self.isShown else { return event }
            self.dismiss()
            return nil
        }
        monitors = [clicks, escape].compactMap { $0 }
    }

    private func unwatch() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// A popup panel that takes the keyboard (a text field, a picker): a ``NativePopupHost`` closes it
/// when it loses the keys, or, shown without them (the app was not active), when another window
/// of the app takes them (``ActiveAppKeyPanel``).
open class NativePopupPanel: ActiveAppKeyPanel {
    /// Set by the host: the panel lost the keys (false), or, shown without them, another window of
    /// the app took them (true).
    var onLostKeys: ((_ elsewhere: Bool) -> Void)?

    public init(identifier: String) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        autorecalculatesKeyViewLoop = true
        collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityIdentifier(identifier)
        setAccessibilityRole(.popover)
        onKeyElsewhere = { [weak self] in self?.onLostKeys?(true) }
    }

    override open var canBecomeMain: Bool { false }

    override open func resignKey() {
        super.resignKey()
        onLostKeys?(false)
    }
}
