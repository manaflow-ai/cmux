public import AppKit
import CmuxNextCompat

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
/// - children: a menu opened from inside the popup (a picker's, a context menu) and a window
///   parented under the panel are part of it. While one is up, its keys, clicks and Escape belong
///   to it: a click, Escape or a pick closes only the inner menu, and the popup takes the keys back.
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
    private(set) var dismissalReason = "outside"
    /// A nested popup temporarily owns the keys; ancestor panels remain open.
    var keepsOpenOnKeyLoss: () -> Bool = { false }
    /// Nested declarative panels observe their owning window, not ancestor popup layout.
    weak var dismissalWindow: NSWindow?
    /// The control the popup opened from (screen), which it closes toward.
    public private(set) var anchor: CGRect = .zero
    /// Fading out after a hide: gone for the owner and for tests.
    public private(set) var isClosing = false
    /// Bumped by every show and hide: a close whose fade ends after a new show keeps the panel.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    /// The menus AppKit tracks while the popup shows (``MenuTracking``), for ``childMenus``.
    private var menus: MenuTracking?
    private var monitors: [Any] = []
    /// The menus opened from inside the popup that are tracking now (their top menus).
    private var childMenus: Set<ObjectIdentifier> = []
    /// Where the host observes the app's and windows' notices (tests inject their own).
    private let center: NotificationCenter

    public init(panel: NSPanel, notificationCenter: NotificationCenter = .default) {
        self.panel = panel
        center = notificationCenter
        if let keyed = panel as? NativePopupPanel {
            keyed.onLostKeys = { [weak self] elsewhere in
                let press = NSApp.currentEvent.flatMap { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) ? $0 : nil }
                self?.lostKeys(elsewhere: elsewhere, press: press)
            }
        }
    }

    /// The panel lost the keys (``NativePopupPanel/onLostKeys``) during `press`, the mouse-down
    /// being handled then (nil for none).
    func lostKeys(elsewhere: Bool, press: NSEvent?) {
        guard let keyed = panel as? NativePopupPanel else { return }
        if keepsOpenOnKeyLoss() { return }
        // A menu or window opened from inside the popup took the keys: the popup stays, and takes
        // them back when the menu closes.
        if hasOpenChild { return }
        // A press on the control that toggles the popup makes its window key first; the control
        // closes the popup itself, so that key loss is not a dismiss.
        if let press, press.window !== keyed, keepsOpen(press) { return }
        // A press inside the popup lost it the keys before a menu it opened began tracking (AppKit
        // may resign the panel first). Once the press is handled (the menu's tracking, which
        // starts inside it, is noted synchronously) the popup closes unless a child took them.
        if let press, contains(press.window) {
            let showing = generation
            // task-owner: one deferred dismiss check after the press, on the main actor; it checks the generation itself
            Task { @MainActor [weak self] in
                guard let self, self.generation == showing, self.isShown, !self.hasOpenChild, !self.panel.isKeyWindow else { return }
                self.dismiss()
            }
            return
        }
        // Shown without the keys, a window of the app took them without a press (Cmd-Tab into the
        // app, a focus request): the popup takes them over, as a popup shown with the app active
        // has them; it never takes them while the app is inactive (ActiveAppKeyPanel). A press
        // elsewhere closes it through the click monitor.
        if elsewhere, press == nil, isShown {
            keyed.makeKey()
            return
        }
        dismiss()
    }

    /// The popup is on screen and not closing.
    public var isShown: Bool { panel.isVisible && !isClosing }

    /// A menu opened from inside the popup is tracking, or the key window is one parented under it.
    var hasOpenChild: Bool {
        if !childMenus.isEmpty { return true }
        guard let key = NSApp.keyWindow, key !== panel else { return false }
        return contains(key)
    }

    /// `window` is the panel or a window parented under it.
    private func contains(_ window: NSWindow?) -> Bool {
        var window = window
        while let current = window {
            if current === panel { return true }
            window = current.parent
        }
        return false
    }

    /// `menu` (a top menu) opened from inside the popup: it belongs to a view in the panel (a
    /// pop-up button's, a view's context menu), or the event that opened it was in the popup.
    /// The menu bar's menus never are.
    private func opensFromPopup(_ menu: NSMenu) -> Bool {
        if let main = NSApp.mainMenu, menu === main { return false }
        if let root = panel.contentView, Self.view(in: root, owns: menu) { return true }
        return contains(NSApp.currentEvent?.window)
    }

    private static func view(in view: NSView, owns menu: NSMenu) -> Bool {
        if view.menu === menu { return true }
        return view.subviews.contains { Self.view(in: $0, owns: menu) }
    }

    private static func topMenu(_ menu: NSMenu) -> NSMenu {
        var top = menu
        while let parent = top.supermenu { top = parent }
        return top
    }

    private func menuBegan(_ menu: NSMenu) {
        let top = Self.topMenu(menu)
        guard isShown, opensFromPopup(top) else { return }
        childMenus.insert(ObjectIdentifier(top))
    }

    private func menuEnded(_ menu: NSMenu) {
        guard childMenus.remove(ObjectIdentifier(Self.topMenu(menu))) != nil, childMenus.isEmpty, isShown else { return }
        // The menu gave the keys up: they come back to the popup (only while the app is active,
        // for an ActiveAppKeyPanel).
        if !panel.isKeyWindow { panel.makeKey() }
    }

    /// The card's frame (screen), without the shadow band.
    public var cardFrame: CGRect { PopupStyle.standard.cardFrame(inWindow: panel.frame) }

    /// Shows (or moves) the popup with a card of `size` at `anchor` (screen) over `window`.
    /// `trailing` and `centered` align it on the anchor (``PopupPlacement/frame(anchor:size:preferred:trailing:centered:screen:gap:margin:)``).
    /// `makeKey` gives it the keys (a ``NativePopupPanel`` takes them only while the app is
    /// active). The popup shows in one frame, with no grow or fade in; its close still fades.
    /// `tooltipEntrance` is for a page tooltip only (``WebPopupHost``): it fades and grows in
    /// (``NSWindow/openTooltipWithEntrance(pivot:)``). Menus and popovers never pass it.
    /// Returns the card frame and the side it took, or nil when it cannot show.
    @discardableResult
    public func show(size: CGSize, anchor: CGRect, in window: NSWindow, preferred: PopupPlacement.Side = .below,
                     trailing: Bool = false, centered: Bool = false, makeKey: Bool = false,
                     tooltipEntrance: Bool = false, sideBySide: Bool = false) -> (frame: CGRect, side: PopupPlacement.Side)? {
        guard window.isVisible, let screen = PopupPlacement.screen(for: anchor, fallback: window) else { return nil }
        let frame: CGRect
        let side: PopupPlacement.Side
        if sideBySide {
            frame = PopupPlacement.sideBySideFrame(anchor: anchor, size: size, screen: screen.visibleFrame).frame
            // Side-by-side placement follows the row vertically; preserve the conventional side
            // in the return value for callers that only record the vertical preference.
            side = preferred
        } else {
            let placed = PopupPlacement.frame(anchor: anchor, size: size, preferred: preferred, trailing: trailing,
                                              centered: centered, screen: screen.visibleFrame)
            frame = placed.frame
            side = placed.side
        }
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
        if opening {
            let pivot = panel.popupPivot(toward: anchor)
            if tooltipEntrance { panel.openTooltipWithEntrance(pivot: pivot) } else { panel.openPopup(pivot: pivot) }
        }
        watch(dismissalWindow ?? window)
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

    /// Closes the popup and its panel for good (its owner is going away): ``hide()`` only orders
    /// the panel out, so it would stay in the app's window list. A later ``show`` opens it again.
    public func closePanel() {
        hide()
        panel.parent?.removeChildWindow(panel)
        panel.close()
    }

    /// Closes the popup by a dismiss rule: ``hide()``, then ``onDismiss``.
    public func dismiss(reason: String = "outside") {
        guard isShown else { return unwatch() }
        dismissalReason = reason
        hide()
        onDismiss?()
    }

    private func watch(_ window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = self.center
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
        // A menu opened from inside the popup, noted as AppKit posts it (MenuTracking delivers at
        // once, inside the press that opens the menu) so a key loss checked after the press sees it.
        let menus = MenuTracking(center: center)
        menus.subscribe { [weak self] change in
            switch change {
            case .began(let menu): self?.menuBegan(menu)
            case .ended(let menu): self?.menuEnded(menu)
            }
        }
        self.menus = menus
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, !self.contains(event.window), !self.hasOpenChild, !self.keepsOpen(event) else { return event }
            self.dismiss()
            return event
        }
        // Escape in the popup closes it (a text field in it would otherwise take it as cancel);
        // with a menu of the popup open, Escape closes only that menu.
        let escape = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 53, self.isShown, self.childMenus.isEmpty else { return event }
            // The input method owns Escape while cancelling marked text. Closing the popup
            // here would discard the composition before the editor sees the key.
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            self.dismiss(reason: "escape")
            return nil
        }
        monitors = [clicks, escape].compactMap { $0 }
    }

    private func unwatch() {
        observers.forEach(center.removeObserver)
        observers = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        menus = nil
        childMenus = []
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
