public import AppKit

/// A one-line AppKit label whose text color blends on a theme change (I5, cx-8w027.3): it keeps
/// `NSTextField`'s layout (intrinsic size, alignment, truncation, accessibility) and draws its
/// string with a ``ChromeTextLayer``, so ``textColor`` is a layer color the render server blends
/// from the color on screen (`ThemeRepaint`) and a color change redraws no glyphs. For plain
/// strings only: per-run colors of an attributed string are not drawn (use `NSTextField`).
public final class ChromeLabel: NSTextField {
    private let text = ChromeTextLayer()

    public convenience init(font: NSFont) {
        self.init(labelWithString: "")
        self.font = font
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
    }

    override public var wantsUpdateLayer: Bool { true }

    override public var stringValue: String {
        didSet { needsDisplay = true }
    }

    override public var font: NSFont? {
        didSet { needsDisplay = true }
    }

    override public var textColor: NSColor? {
        didSet { text.foregroundColor = textColor?.cgColor }
    }

    override public var alignment: NSTextAlignment {
        didSet { needsDisplay = true }
    }

    override public var lineBreakMode: NSLineBreakMode {
        didSet { needsDisplay = true }
    }

    override public func updateLayer() {
        guard let layer else { return }
        if text.superlayer !== layer {
            text.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
            layer.addSublayer(text)
        }
        text.string = stringValue
        text.font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        text.foregroundColor = textColor?.cgColor
        text.truncation = switch lineBreakMode {
        case .byTruncatingTail: .end
        case .byTruncatingMiddle: .middle
        case .byTruncatingHead: .start
        default: nil
        }
        text.alignmentMode = switch alignment {
        case .center: .center
        case .right: .right
        case .natural: userInterfaceLayoutDirection == .rightToLeft ? .right : .left
        default: .left
        }
        text.contentsScale = window?.backingScaleFactor ?? layer.contentsScale
        layoutText()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? text.contentsScale
    }

    override public func layout() {
        super.layout()
        layoutText()
    }

    /// Where the cell draws its title: the same inset and top as an `NSTextField` label.
    private func layoutText() {
        let rect = cell?.titleRect(forBounds: bounds) ?? bounds
        guard text.frame != rect else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.frame = rect
        CATransaction.commit()
    }
}
