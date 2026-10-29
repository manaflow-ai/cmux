public import AppKit
public import CmuxNextInput
public import CmuxNextWakeups

/// The one native host for the popups that open from the omnibar and the toolbar (Lawrence
/// 2026-10-14: "omnibar stuff should be macos specific so it feels more native"; hq
/// `.cmux-scratch/omnibar-popups/REUSE.md`). A popup is a borderless child panel of its window in
/// the popup style (``NSPanel/adoptPopupStyle(card:)``), so it draws above Chromium page windows
/// and moves with the window. The host owns what every popup shares:
///
/// - placement: below the anchor or above it on the screen (``PopupPlacement``);
/// - motion: opens in one frame by default; an explicit entrance grows out of the anchor and
///   shrinks back toward it on the card's layer (``NSWindow/openPopup(pivot:entrance:)``);
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
    /// The control the popup opened from (screen), which it grows from and shrinks toward.
    public private(set) var anchor: CGRect = .zero
    /// Fading out after a hide: gone for the owner and for tests.
    public private(set) var isClosing = false
    /// Bumped by every show and hide: a close whose fade ends after a new show keeps the panel.
    private var generation = 0
    /// While the popup shows: the notices that close it (the app going inactive; its window moving,
    /// resizing, closing or minimizing), through the app's ``AppEvents`` and the window's ``WindowEvents``.
    private var dismissals: [EventSubscription] = []
    /// Where the app's going inactive arrives (an owner may set the app's one): by default a keyed panel's own
    /// (``ActiveAppKeyPanel/appEvents``), else one on the default center.
    public lazy var appEvents: AppEvents = (panel as? ActiveAppKeyPanel)?.appEvents ?? AppEvents(center: .default)
    /// A window's notices: the window's one ``WindowEvents`` (tests set their own center's).
    var windowEvents: @MainActor (NSWindow) -> WindowEvents = { WindowEvents.of($0) }
    /// While the popup shows: the tap observer of clicks (one outside the popup closes it) and the
    /// Escape intercept (``InputEventTap/InterceptOrder/popup``, after a modal overlay's).
    private var subscriptions: [InputSubscription] = []
    /// The tap this popup subscribes to while it shows.
    var inputTap: InputEventTap?
    /// The last press the click observer saw (``clickEvent(_:)``).
    private var lastPress: NSEvent?

    /// A host for `panel` that subscribes to `input` (nil: the overlay hosts' tap,
    /// ``WindowOverlayHost/appInputTap``).
    public init(panel: NSPanel, input: InputEventTap? = nil) {
        self.panel = panel
        inputTap = input ?? WindowOverlayHost.appInputTap
        if let keyed = panel as? NativePopupPanel {
            keyed.onLostKeys = { [weak self, weak keyed] elsewhere in
                guard let self, let keyed else { return }
                // A press on the control that toggles the popup makes its window key first; the
                // control closes the popup itself, so that key loss is not a dismiss.
                let press = dispatchedPress()
                if let press, press.window !== keyed, keepsOpen(press) { return }
                // Shown without the keys, a window of the app took them without a press (Cmd-Tab
                // into the app, a focus request): the popup takes them over, as a popup shown with
                // the app active has them; it never takes them while the app is inactive
                // (ActiveAppKeyPanel). A press elsewhere closes it through the click observer.
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
    /// active). `entrance` false shows it in one frame, with no grow or fade in (its close still
    /// fades). Returns the card frame and the side it took, or nil when it cannot show.
    @discardableResult
    public func show(size: CGSize, anchor: CGRect, in window: NSWindow, preferred: PopupPlacement.Side = .below,
                     trailing: Bool = false, centered: Bool = false, makeKey: Bool = false,
                     entrance: Bool = false) -> (frame: CGRect, side: PopupPlacement.Side)? {
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
        if opening {
            if entrance { panel.openPopup(pivot: panel.popupPivot(toward: anchor), entrance: true) } else { panel.showPopupAtOnce() }
        }
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
        if dismissals.isEmpty {
            // The popup closes in the notice's own turn, as Chromium's bubble closes when its widget deactivates
            // (BubbleDialogDelegate's close_on_deactivate, ui/views/bubble/bubble_dialog_delegate_view.cc).
            let close: @MainActor () -> Void = { [weak self] in self?.dismiss() }
            let events = windowEvents(window)
            dismissals = [
                appEvents.subscribe(NSApplication.didResignActiveNotification, owner: "NativePopupHost", close),
                events.subscribe(NSWindow.willMoveNotification, owner: "NativePopupHost", close),
                events.subscribe(NSWindow.didResizeNotification, owner: "NativePopupHost", close),
                events.subscribe(NSWindow.willCloseNotification, owner: "NativePopupHost", close),
                events.subscribe(NSWindow.didMiniaturizeNotification, owner: "NativePopupHost", close),
            ]
        }
        guard subscriptions.isEmpty, let tap = requiredInputTap(inputTap, owner: "NativePopupHost") else { return }
        let shows: @MainActor () -> Bool = { [weak self] in self?.isShown == true }
        subscriptions = [
            tap.subscribe(class: .button, while: shows) { [weak self] event in self?.clickEvent(event) },
            tap.subscribe(class: .key, phase: .intercept(order: .popup), while: shows) { [weak self] event in
                self?.escapeEvent(event) ?? .pass
            },
        ]
    }

    /// A button event seen by the click observer: a press outside the popup that does not keep it
    /// open closes it (the press goes on to where it landed).
    func clickEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            lastPress = event
            guard event.window !== panel, !keepsOpen(event) else { return }
            dismiss()
        default:
            break
        }
    }

    /// The press being dispatched now, which moves the keys: the click observer's last press while
    /// it is still the tap's last dispatched event; nil for a key loss no press of the app made.
    func dispatchedPress() -> NSEvent? {
        guard let press = lastPress, inputTap?.isLastDispatched(press) == true else { return nil }
        return press
    }

    /// A key event of the Escape intercept: Escape in the popup closes it, and nothing else gets it
    /// (a text field in it would otherwise take it as cancel).
    func escapeEvent(_ event: NSEvent) -> InputEventTap.InterceptResult {
        guard event.type == .keyDown, event.window === panel, event.keyCode == 53, isShown else { return .pass }
        dismiss()
        return .consume
    }

    private func unwatch() {
        dismissals.forEach { $0.cancel() }
        dismissals = []
        subscriptions = []
        lastPress = nil
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
