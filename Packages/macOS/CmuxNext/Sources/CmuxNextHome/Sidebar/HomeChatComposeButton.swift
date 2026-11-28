import AppKit
import CmuxNextDesign

/// The chat's compose button while the Home list shows avatars only: Messages' round Liquid Glass
/// button at the chat's top-left, beside the traffic lights (refs/imessage-layout/2.png). It runs
/// the list's own New Message action and right-click menu (`HomeSidebarView.newMessage`).
final class HomeChatComposeButton: ClickableButton {
    /// The button's side: the top row's (`TitlebarBandButton.side`), so Chats and compose read as the
    /// same kind of control as the sidebar toggle, Back, Forward and + beside them. The 30 pt Liquid
    /// Glass circles stood out as two big bubbles next to the flat top row (the person, 2026-11-28:
    /// "this part is pretty bad").
    static var side: CGFloat { TitlebarBandButton.side }
    /// A right-click menu (the list compose's: New Chief, Invite).
    var contextMenu: (() -> NSMenu?)?

    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        HomeChatTopRowLook.apply(to: self, symbol: "square.and.pencil")
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("cmux.home.chat.compose")
        themedToolTip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        HomeChatTopRowLook.layout(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        HomeChatTopRowLook.applyInk(to: self, lit: false)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { NSMenu.withoutSystemItems(contextMenu?() ?? super.menu(for: event)) }
}

/// The chat's Chats and compose buttons drawn as the top row's flat buttons (`TitlebarBandButton`):
/// no bezel, the band's glyph size and ink, a rounded fill on hover and while lit.
@MainActor
enum HomeChatTopRowLook {
    static func apply(to button: NSButton, symbol: String) {
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Metrics.toolbarSymbolPointSize,
                                                                 weight: Metrics.toolbarSymbolWeight))
        let hover = ChromeHover(button, behindContent: true)
        hover.followPointer()
        objc_setAssociatedObject(button, &hoverKey, hover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        applyInk(to: button, lit: false)
    }

    static func hover(of button: NSButton) -> ChromeHover? {
        objc_getAssociatedObject(button, &hoverKey) as? ChromeHover
    }

    static func layout(_ button: NSButton) {
        button.layer?.cornerRadius = Metrics.toolbarButtonCornerRadius(side: button.bounds.height)
    }

    /// The band's secondary ink at rest, the accent while lit (the list shows).
    static func applyInk(to button: NSButton, lit: Bool) {
        hover(of: button)?.state.lit = lit
        button.performWithTheme {
            button.contentTintColor = lit ? .controlAccentColor : Palette.textSecondary
        }
    }

    nonisolated(unsafe) private static var hoverKey: UInt8 = 0
}
