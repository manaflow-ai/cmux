import AppKit
import CmuxNextDesign

/// "Exit 101" with Fix and a close button, in the bottom-trailing corner of a terminal whose shell
/// just reported a failed command (OSC 133 `D` with a nonzero status; design/terminal-fix-chip-gallery.html,
/// variant A). Fix sends the command, its status, its output and its folder to the workspace's agent
/// chat (`terminal.fixLastCommand`). Styled like ``TerminalSizedForChip``, on the pane's one material;
/// only the buttons take clicks.
final class TerminalFixChip: NSView {
    private let label = ThemedLabel(labelWithString: "")
    private let fixButton: NSButton
    private let closeButton: NSButton
    private let stack = NSStackView()
    /// Fix: the App's `terminal.fixLastCommand` for this tab.
    var onFix: (@MainActor () -> Void)?
    /// The close button: the chip hides until the next failed command.
    var onDismiss: (@MainActor () -> Void)?
    private(set) var shownExitCode: Int?

    init() {
        let fix = ModuleResourceBundle.terminal.text("terminal.fixChip.fix", defaultValue: "Fix")
        fixButton = NSButton(title: fix, target: nil, action: nil)
        closeButton = NSButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.surfaceCornerRadius
        layer?.borderWidth = Metrics.lineWidth(1)
        label.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.emphasis)
        label.ink = .secondary
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fixButton.bezelStyle = .rounded
        fixButton.controlSize = .small
        fixButton.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        fixButton.toolTip = ModuleResourceBundle.terminal.text("terminal.fixChip.fixHelp",
                                                               defaultValue: "Send the command, its output and its folder to the agent chat")
        fixButton.setAccessibilityLabel(fix)
        fixButton.target = self
        fixButton.action = #selector(fixClicked)
        let close = ModuleResourceBundle.terminal.text("terminal.fixChip.dismiss", defaultValue: "Dismiss")
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: close)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.controlSize = .small
        closeButton.toolTip = close
        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        stack.setViews([label, fixButton, closeButton], in: .leading)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    private func applyThemeColors() {
        performWithTheme {
            // glass-opaque-allow: an in-pane chip over terminal text that must stay readable, the "Sized for" chip's label (design/terminal.md)
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
            fixButton.contentTintColor = Palette.textSecondary
            fixButton.bezelColor = Palette.selectionFill
            closeButton.contentTintColor = Palette.textTertiary
        }
    }

    /// Only the buttons are targets; the rest of the chip lets clicks reach the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === fixButton || hit === closeButton ? hit : nil
    }

    /// Shows the chip for a command that exited with `exitCode`, or hides it (nil). It fades in on
    /// `fadeIn` when it appears; a later failure while it shows only changes the text.
    func show(exitCode: Int?) {
        shownExitCode = exitCode
        guard let exitCode else {
            isHidden = true
            return
        }
        let text = Self.text(exitCode: exitCode)
        label.stringValue = text
        setAccessibilityLabel(text)
        if isHidden, let layer {
            let seconds = Motion.overlays.duration(.fadeIn)
            if seconds > 0 {
                // motion-allow: a fade on Motion's .fadeIn duration and fadeCurve, skipped when Motion says 0
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = seconds
                fade.timingFunction = Motion.fadeCurve
                layer.add(fade, forKey: "terminalFixChip.reveal")
            }
        }
        isHidden = false
    }

    @objc private func fixClicked() { onFix?() }
    @objc private func dismissClicked() { onDismiss?() }

    /// "Exit 101".
    static func text(exitCode: Int, strings: ModuleResourceBundle = .terminal) -> String {
        strings.text("terminal.fixChip.exit", defaultValue: "Exit \(exitCode)")
    }

    /// Whether a finished command offers Fix: a nonzero status, except an interrupt the person
    /// typed (Ctrl-C ends a command with 130) — that is a choice, not a failure.
    static func offersFix(exitCode: Int?) -> Bool {
        guard let exitCode else { return false }
        return exitCode != 0 && exitCode != 130
    }
}
