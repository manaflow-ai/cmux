public import AppKit
public import CmuxNextDesign

/// Which face of a terminal and chat pair the selected tab is (`design/terminal-chat-toggle.md`).
public enum PaneTerminalChatFace: String, Equatable, Sendable {
    case terminal, chat
}

/// Toggle Terminal and Chat's control in the pane toolbar (``PaneToolbarView``): two square icon segments,
/// the terminal's `>_` and the chat's bubble, the selected tab's face lit (Leo 2026-11-12: "we can toggle it,
/// like from the terminal into the GUI, or vice versa, back and forth"). It shows at rest, never faded with
/// the bar's other tools, at the same x on both faces. A press on the other face runs the action
/// (`palette.toggleTerminalChat`), so the click and the key are one path; a press on the lit face does nothing.
/// VoiceOver reads a radio group (what AppKit's segmented controls are) of "Terminal" and "Chat".
public final class PaneTerminalChatToggleView: NSView {
    public let terminalButton = TitlebarBandButton(symbol: "terminal")
    public let chatButton = TitlebarBandButton(symbol: "bubble.left")
    /// The selected tab's face; nil hides the control.
    public private(set) var face: PaneTerminalChatFace?
    /// The other face was pressed.
    public var onSwap: (() -> Void)?

    /// Its width: two buttons' squares and the bar's gap between them.
    public static var width: CGFloat { 2 * TitlebarBandButton.side + Metrics.space1 / 2 }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityIdentifier("cmux.pane.terminalChatToggle")
        for (button, face) in [(terminalButton, PaneTerminalChatFace.terminal), (chatButton, .chat)] {
            button.target = self
            button.action = #selector(press(_:))
            button.longPressOpensMenu = false
            button.refusesFirstResponder = true
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(face == .terminal ? Strings.terminalFace : Strings.chatFace)
            button.setAccessibilityIdentifier("cmux.pane.terminalChatToggle.\(face.rawValue)")
            addSubview(button)
        }
        isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { false }

    /// Shows `face` lit, or hides the control (nil); `title` and `shortcut` are the action's, for the tooltip.
    public func show(_ face: PaneTerminalChatFace?, title: String, shortcut: String?) {
        self.face = face
        isHidden = face == nil
        setAccessibilityLabel(title)
        for (button, segment) in [(terminalButton, PaneTerminalChatFace.terminal), (chatButton, .chat)] {
            let on = segment == face
            button.state = on ? .on : .off
            button.hover.state.lit = on
            button.setAccessibilityValue(on ? 1 : 0)
            button.themedToolTip = title
            button.themedToolTipShortcut = shortcut
        }
        applyTint()
    }

    override public func layout() {
        super.layout()
        let side = TitlebarBandButton.side, gap = Metrics.space1 / 2
        terminalButton.frame = NSRect(x: 0, y: 0, width: side, height: side)
        chatButton.frame = NSRect(x: side + gap, y: 0, width: side, height: side)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    /// The lit face in the lit glyph, the other in the chrome's secondary text, as the bar's toggled tools.
    private func applyTint() {
        terminalButton.contentTintColor = performWithTheme { face == .terminal ? Palette.litGlyph : Palette.textSecondary }
        chatButton.contentTintColor = performWithTheme { face == .chat ? Palette.litGlyph : Palette.textSecondary }
    }

    @objc private func press(_ sender: TitlebarBandButton) {
        guard let face else { return }
        let pressed: PaneTerminalChatFace = sender === terminalButton ? .terminal : .chat
        guard pressed != face else { return }
        onSwap?()
    }
}
