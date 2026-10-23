public import AppKit
public import CmuxNextDesign

/// The floating glass panel that carries the permission card, top center
/// of the screen, over every app (System Settings included).
///
/// It is non-activating: showing it never takes the person's keyboard or
/// raises cmux. It becomes key only when the person clicks into it, so Esc
/// and Return reach the card then and never before.
public final class PermissionRequestPanel: NSPanel {
    /// The card it carries.
    public let card: PermissionRequestCardView
    private let surface: OverlaySurfaceView

    /// - Parameters:
    ///   - card: the card to carry.
    ///   - theme: the scope it draws in: the app's root (`AppServices.themeRoot`), as it belongs
    ///     to no room.
    public init(card: PermissionRequestCardView, theme: ThemeScope) {
        self.card = card
        surface = Glass.makeOverlayPanel(content: nil)
        super.init(contentRect: NSRect(x: 0, y: 0, width: PermissionRequestCardView.width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        level = .floating
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        surface.translatesAutoresizingMaskIntoConstraints = true
        contentView = surface
        card.translatesAutoresizingMaskIntoConstraints = true
        card.autoresizingMask = [.width, .height]
        surface.contentView.addSubview(card)
        theme.adopt(self)
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// Sizes the panel to the card and places it top center of `screen`
    /// (the screen of cmux's key window, else the main screen), then shows it
    /// without activating cmux.
    public func present(on screen: NSScreen?) {
        card.layoutSubtreeIfNeeded()
        let size = NSSize(width: PermissionRequestCardView.width, height: ceil(card.fittingSize.height))
        surface.frame = NSRect(origin: .zero, size: size)
        surface.layoutSubtreeIfNeeded()
        card.frame = surface.contentView.bounds
        setContentSize(size)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
        }
        orderFrontRegardless()
    }

    override public func mouseDown(with event: NSEvent) {
        makeKey()
        makeFirstResponder(card)
        super.mouseDown(with: event)
    }
}
