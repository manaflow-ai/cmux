public import AppKit

/// An icon button of the toolbar band and the pane's tab bar controls: the chrome's hover and
/// pressed look.
public final class TitlebarBandButton: NSButton {
    public static var side: CGFloat { Metrics.sidebarRowHeight - Metrics.space1 }
    /// The SF Symbol it draws, or a custom glyph name ``customImage`` draws.
    public var symbol: String {
        didSet { if symbol != oldValue { renderedIconSize = 0; renderSymbol() } }
    }
    /// Draws a custom glyph name at a point size, or nil for an SF Symbol (the sidebar toggle's
    /// candidates, `SidebarToggleIcon.image(named:pointSize:)`).
    public var customImage: ((String, CGFloat) -> NSImage?)? {
        didSet { renderedIconSize = 0; renderSymbol() }
    }
    private var renderedIconSize: CGFloat = 0
    public private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// Set once `hover` follows the pointer (not during NSButton's init).
    private var followsPointer = false

    public init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        // A collapsing band narrows its items: the glyph scales down with them.
        imageScaling = .scaleProportionallyDown
        renderSymbol()
        contentTintColor = performWithTheme { Palette.textSecondary }
        // Hover follows the pointer and the button's frame (cx-3wu5): a band
        // that collapses or hides under a still pointer clears it.
        hover.followPointer(isHoverable: { [weak self] in self?.isEnabled ?? false })
        followsPointer = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var mouseDownCanMoveWindow: Bool { false }

    /// Disabled under a still pointer (Back with no history left): hover
    /// follows at once (cx-3wu5).
    override public var isEnabled: Bool {
        didSet { if followsPointer, isEnabled != oldValue { hover.pointer?.refresh() } }
    }

    override public func layout() {
        super.layout()
        renderSymbol()
    }

    private func renderSymbol() {
        let size = Metrics.smallIconSize
        guard size != renderedIconSize else { return }
        renderedIconSize = size
        image = customImage?(symbol, size)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    /// A right-click or long-press menu (Back / Forward lists); the sidebar toggle's opens on right-click only.
    public var menuProvider: (() -> NSMenu?)?, longPressOpensMenu = true
    /// A menu that opens on press, like a pop-up button (the pane toolbar's "…"): press, drag
    /// to a row and release to run it; a plain click leaves it open. The action still runs
    /// for a keyboard or VoiceOver press.
    public var pressMenu: (() -> NSMenu?)?
    /// Shows a menu under the button (tests record it instead).
    public var presentMenu: @MainActor (NSMenu, TitlebarBandButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: button, gap: Metrics.space1), in: button)
    }

    /// The right-click (and Control-click) menu opens while the button is disabled too (Back
    /// with nowhere to go still lists Recently Closed); its click and long press stay off.
    public var opensMenuWhenDisabled = false
    /// Shows the right-click menu (tests record it instead).
    public var presentContextMenu: @MainActor (NSMenu, NSEvent, TitlebarBandButton) -> Void = { menu, event, button in
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    override public func rightMouseDown(with event: NSEvent) {
        guard isEnabled || opensMenuWhenDisabled else { return }
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        presentContextMenu(menu, event, self)
    }

    /// A long press shows the menu like a browser's Back button; a click runs.
    override public func mouseDown(with event: NSEvent) {
        // Control-click is a right-click: a disabled button may still open its menu.
        if event.modifierFlags.contains(.control), menuProvider != nil, pressMenu == nil {
            return rightMouseDown(with: event)
        }
        guard isEnabled else { return }
        if let pressMenu {
            guard let menu = pressMenu(), !menu.items.isEmpty else { return }
            // Pressed while its menu is open, like a pop-up button.
            isHighlighted = true
            defer { isHighlighted = false }
            presentMenu(menu, self)
            return
        }
        guard menuProvider != nil, longPressOpensMenu, let window else { return super.mouseDown(with: event) }
        let deadline = Date().addingTimeInterval(NSEvent.doubleClickInterval)
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { sendAction(action, to: target); return }
        }
        if let menu = menuProvider?() { presentMenu(menu, self) }
    }
}
