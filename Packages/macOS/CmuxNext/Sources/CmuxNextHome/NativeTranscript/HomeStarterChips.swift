import AppKit
import CmuxNextDesign

/// Quiet, wrapping prompt chips. Alternate arrangements are exercised by the native gallery.
final class HomeStarterChips: NSView {
    enum Look: String, CaseIterable { case wrapped, stacked, plain }
    var look: Look = .wrapped { didSet { needsLayout = true; repaint() } }
    private(set) var prompts: [String] = []
    private(set) var buttons: [NSButton] = []
    var onSend: (String) -> Void = { _ in }
    var isEnabled = true { didSet { if isEnabled != oldValue { for button in buttons { button.isEnabled = isEnabled } } } }
    private var scale: CGFloat = 1
    private var text = NSColor.labelColor, fill = NSColor.clear

    nonisolated override var isFlipped: Bool { true }

    func setPrompts(_ prompts: [String]) {
        guard prompts != self.prompts else { return }
        let focused = buttons.firstIndex { window?.firstResponder === $0 }.map { self.prompts[$0] }
        self.prompts = prompts
        for button in buttons { button.removeFromSuperview() }
        buttons = prompts.map { prompt in
            let button = NSButton(title: prompt, target: self, action: #selector(sendPrompt(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.setAccessibilityLabel(prompt)
            button.isEnabled = isEnabled
            button.cell?.lineBreakMode = .byTruncatingTail
            addSubview(button)
            return button
        }
        repaint()
        needsLayout = true
        if let focused { window?.makeFirstResponder(buttons.first { $0.title == focused } ?? buttons.first) }
    }

    func applyScale(_ value: CGFloat) { scale = value; repaint(); needsLayout = true }
    func applyColors(text: NSColor, fill: NSColor) { self.text = text; self.fill = fill; repaint() }

    private func repaint() {
        for button in buttons {
            button.font = .systemFont(ofSize: TypeScale.Base.detail * scale)
            button.contentTintColor = text
            button.layer?.backgroundColor = look == .plain ? NSColor.clear.cgColor : fill.cgColor
            button.layer?.cornerRadius = 12 * scale
        }
    }

    /// The same layout measures and places chips, including narrow panes and long translations.
    @discardableResult func measure(width: CGFloat, place: Bool = false) -> CGFloat {
        guard !buttons.isEmpty else { return 0 }
        let gap = 6 * scale, height = 28 * scale
        var x: CGFloat = 0, y: CGFloat = 0
        for button in buttons {
            let w = look == .stacked ? width : min(width, ceil(button.intrinsicContentSize.width) + 20 * scale)
            if x > 0, x + w > width { x = 0; y += height + gap }
            if place { button.frame = CGRect(x: x, y: y, width: w, height: height) }
            x += w + gap
        }
        return y + height
    }

    override func layout() { super.layout(); measure(width: bounds.width, place: true) }

    @objc private func sendPrompt(_ sender: NSButton) {
        guard isEnabled, !isHiddenOrHasHiddenAncestor, buttons.contains(sender) else { return }
        onSend(sender.title)
    }
}
