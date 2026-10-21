public import AppKit
import CmuxNextDesign

/// The Add Server card: a rounded glass panel floating near the top center of the cmux window,
/// on every Space and over full screen (u3849: pairing does not belong in the menu bar). It never
/// activates the app. A request that arrives on its own (a pairing link, a script) shows without
/// taking the keys, so typing in the window behind goes on; a click on the card, or opening it by
/// hand (palette, Settings), gives it the keys, and then Return approves and Escape denies.
@MainActor
public final class AddServerCardPanel: NSPanel {
    /// The gap between the window's top edge and the card's.
    public static let topInset: CGFloat = 56

    public let model: ServerModel
    private let host: ServerHostView

    /// - Parameter model: The server model whose Add Server flow the card shows.
    public init(model: ServerModel) {
        self.model = model
        host = ServerHostView(model: model, surface: .approver)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: 200)),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.addServerCard")
        host.autoresizingMask = [.width, .height]
        contentView = host
        host.onDismiss = { [weak self] in self?.orderOut(nil) }
        host.onContentSize = { [weak self] size in self?.fit(size) }
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// Shows the card over `window` (the cmux window it belongs to; nil uses the screen's top).
    /// `takeKeys` is true when the user opened it by hand and is about to type the code.
    public func present(over window: NSWindow?, takeKeys: Bool) {
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        let size = host.fittingSize
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        setFrame(Self.placement(size: size, over: window?.frame, in: visible), display: false)
        WindowActivation.show(self, takeKeys ? .raise : .bringForward)
    }

    /// Escape while the card has the keys: the same as its Cancel or Deny button.
    override public func cancelOperation(_ sender: Any?) {
        if model.perform(.cancel) { orderOut(nil) }
    }

    /// Horizontally centered on `parent`, its top `topInset` below the parent's top, kept inside
    /// `visible`; with no parent, the top center of `visible`.
    public static func placement(size: CGSize, over parent: NSRect?, in visible: NSRect) -> NSRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let anchor = parent ?? visible
        let x = min(max(anchor.midX - width / 2, visible.minX), visible.maxX - width)
        let top = min(anchor.maxY, visible.maxY) - topInset
        let y = min(max(top - height, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// The card's content changed height (a server was found, an error showed): grow or shrink
    /// downward, keeping the top edge where the user saw it.
    private func fit(_ size: NSSize) {
        guard size.height > 0, abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}
