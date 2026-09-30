import AppKit

/// A small rounded pill button used for the harness and model pickers.
final class AcpmuxChipButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        font = .systemFont(ofSize: 11, weight: .medium)
        imagePosition = .noImage
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(title: String, theme: AcpmuxChatTheme) {
        attributedTitle = NSAttributedString(string: "\(title) \u{25BE}", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: theme.secondaryText,
        ])
        layer?.backgroundColor = theme.codeBackground.cgColor
        sizeToFit()
        frame.size = CGSize(width: frame.width + 16, height: 18)
    }

    override func mouseDown(with event: NSEvent) {
        guard let menu else {
            super.mouseDown(with: event)
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
