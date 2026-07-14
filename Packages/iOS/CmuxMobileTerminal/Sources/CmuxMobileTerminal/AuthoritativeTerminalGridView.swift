#if canImport(UIKit)
import CMUXMobileCore
import UIKit

/// Draws one immutable producer-authored grid using absolute terminal cells.
@MainActor
final class AuthoritativeTerminalGridView: UIView {
    private var state: AuthoritativeTerminalGridState
    private let cursorLayer = CAShapeLayer()
    var terminalFontSize: CGFloat = 10 {
        didSet {
            guard terminalFontSize != oldValue else { return }
            setNeedsDisplay()
        }
    }

    init(surfaceID: String) {
        self.state = AuthoritativeTerminalGridState(surfaceID: surfaceID)
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = true
        isUserInteractionEnabled = false
        layer.zPosition = 900
        cursorLayer.actions = [
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull()
        ]
        layer.addSublayer(cursorLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present(
        _ frame: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        let result = state.apply(frame)
        guard result == .presented else { return result }
        setNeedsDisplay()
        setNeedsLayout()
        return result
    }

    func reset(surfaceID: String) {
        state.reset(surfaceID: surfaceID)
        cursorLayer.isHidden = true
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateCursorLayer()
    }

    override func draw(_ rect: CGRect) {
        guard let frame = state.frame,
              frame.columns > 0,
              frame.rows > 0,
              let context = UIGraphicsGetCurrentContext() else {
            backgroundColorForCurrentFrame().setFill()
            UIRectFill(bounds)
            return
        }

        let theme = TerminalThemeStore.current
        let defaultBackground = color(
            frame.terminalBackground,
            fallback: color(theme.background, fallback: .black)
        )
        let defaultForeground = color(
            frame.terminalForeground,
            fallback: color(theme.foreground, fallback: .white)
        )
        context.setFillColor(defaultBackground.cgColor)
        context.fill(bounds)

        let cellWidth = bounds.width / CGFloat(frame.columns)
        let cellHeight = bounds.height / CGFloat(frame.rows)
        guard cellWidth > 0, cellHeight > 0 else { return }

        var stylesByID: [Int: MobileTerminalRenderGridFrame.Style] = [:]
        for style in frame.styles {
            stylesByID[style.id] = style
        }
        for span in frame.rowSpans {
            let style = stylesByID[span.styleID] ?? .default
            let spanRect = CGRect(
                x: CGFloat(span.column) * cellWidth,
                y: CGFloat(span.row) * cellHeight,
                width: CGFloat(span.gridCellWidth) * cellWidth,
                height: cellHeight
            )
            guard spanRect.intersects(rect) else { continue }
            draw(
                span: span,
                style: style,
                environment: SpanDrawingEnvironment(
                    rect: spanRect,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    defaultForeground: defaultForeground,
                    defaultBackground: defaultBackground,
                    context: context
                )
            )
        }
    }
}

private struct SpanDrawingEnvironment {
    let rect: CGRect
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let defaultForeground: UIColor
    let defaultBackground: UIColor
    let context: CGContext
}

private extension AuthoritativeTerminalGridView {
    private func draw(
        span: MobileTerminalRenderGridFrame.RowSpan,
        style: MobileTerminalRenderGridFrame.Style,
        environment: SpanDrawingEnvironment
    ) {
        let colors = resolvedColors(for: style, environment: environment)
        if let background = colors.background {
            environment.context.setFillColor(background.cgColor)
            environment.context.fill(environment.rect)
        }
        guard !style.invisible, !span.text.isEmpty else { return }
        let font = font(for: style, cellHeight: environment.cellHeight)
        let attributes = textAttributes(for: style, font: font, foreground: colors.foreground)
        drawText(span.text, font: font, attributes: attributes, environment: environment)
        if style.overline {
            drawOverline(color: colors.foreground, environment: environment)
        }
    }

    private func resolvedColors(
        for style: MobileTerminalRenderGridFrame.Style,
        environment: SpanDrawingEnvironment
    ) -> (foreground: UIColor, background: UIColor?) {
        var foreground = color(style.foreground, fallback: environment.defaultForeground)
        var background = style.background.map { color($0, fallback: environment.defaultBackground) }
        if style.inverse {
            let originalForeground = foreground
            foreground = background ?? environment.defaultBackground
            background = originalForeground
        }
        if style.faint {
            foreground = foreground.withAlphaComponent(0.55)
        }
        return (foreground, background)
    }

    private func textAttributes(
        for style: MobileTerminalRenderGridFrame.Style,
        font: UIFont,
        foreground: UIColor
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.minimumLineHeight = font.lineHeight
        paragraph.maximumLineHeight = font.lineHeight
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
            .kern: 0,
            .ligature: 0,
            .paragraphStyle: paragraph
        ]
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = foreground
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = foreground
        }
        return attributes
    }

    private func drawText(
        _ text: String,
        font: UIFont,
        attributes: [NSAttributedString.Key: Any],
        environment: SpanDrawingEnvironment
    ) {
        let referenceWidth = max(
            ("M" as NSString).size(withAttributes: [.font: font]).width,
            0.01
        )
        let horizontalScale = environment.cellWidth / referenceWidth
        let baselineY = environment.rect.minY
            + max(0, (environment.cellHeight - font.lineHeight) / 2)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        environment.context.saveGState()
        environment.context.clip(to: environment.rect)
        environment.context.translateBy(x: environment.rect.minX, y: 0)
        environment.context.scaleBy(x: horizontalScale, y: 1)
        attributed.draw(
            with: CGRect(
                x: 0,
                y: baselineY,
                width: environment.rect.width / max(horizontalScale, 0.01),
                height: font.lineHeight
            ),
            options: [.usesFontLeading, .usesLineFragmentOrigin],
            context: nil
        )
        environment.context.restoreGState()
    }

    private func drawOverline(color: UIColor, environment: SpanDrawingEnvironment) {
        environment.context.setStrokeColor(color.cgColor)
        environment.context.setLineWidth(
            max(1 / max(contentScaleFactor, 1), environment.cellHeight * 0.04)
        )
        environment.context.move(to: CGPoint(x: environment.rect.minX, y: environment.rect.minY + 1))
        environment.context.addLine(to: CGPoint(x: environment.rect.maxX, y: environment.rect.minY + 1))
        environment.context.strokePath()
    }

    private func font(
        for style: MobileTerminalRenderGridFrame.Style,
        cellHeight: CGFloat
    ) -> UIFont {
        let requestedSize = min(max(terminalFontSize, 1), max(cellHeight, 1))
        let base = UIFont.monospacedSystemFont(
            ofSize: requestedSize,
            weight: style.bold ? .bold : .regular
        )
        guard style.italic,
              let descriptor = base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(.traitItalic)
              ) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: requestedSize)
    }

    private func updateCursorLayer() {
        guard let frame = state.frame,
              let cursor = frame.cursor,
              cursor.visible,
              frame.columns > 0,
              frame.rows > 0 else {
            cursorLayer.isHidden = true
            cursorLayer.removeAnimation(forKey: "blink")
            return
        }
        let cellWidth = bounds.width / CGFloat(frame.columns)
        let cellHeight = bounds.height / CGFloat(frame.rows)
        let cellRect = CGRect(
            x: CGFloat(cursor.column) * cellWidth,
            y: CGFloat(cursor.row) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        let cursorColor = color(
            frame.terminalCursorColor,
            fallback: color(TerminalThemeStore.current.cursor, fallback: .white)
        )
        cursorLayer.isHidden = false
        cursorLayer.borderColor = nil
        cursorLayer.borderWidth = 0
        applyCursorStyle(cursor.style, cellRect: cellRect, color: cursorColor)
        updateCursorBlink(isBlinking: cursor.blinking)
    }

    private func applyCursorStyle(
        _ style: MobileTerminalRenderGridFrame.Cursor.Style,
        cellRect: CGRect,
        color: UIColor
    ) {
        switch style {
        case .block:
            cursorLayer.frame = cellRect
            cursorLayer.backgroundColor = color.withAlphaComponent(0.72).cgColor
        case .blockHollow:
            cursorLayer.frame = cellRect.insetBy(dx: 0.5, dy: 0.5)
            cursorLayer.backgroundColor = UIColor.clear.cgColor
            cursorLayer.borderColor = color.cgColor
            cursorLayer.borderWidth = max(1 / max(contentScaleFactor, 1), 1)
        case .bar:
            cursorLayer.frame = CGRect(
                x: cellRect.minX,
                y: cellRect.minY,
                width: max(1 / max(contentScaleFactor, 1), cellRect.width * 0.12),
                height: cellRect.height
            )
            cursorLayer.backgroundColor = color.cgColor
        case .underline:
            let height = max(1 / max(contentScaleFactor, 1), cellRect.height * 0.1)
            cursorLayer.frame = CGRect(
                x: cellRect.minX,
                y: cellRect.maxY - height,
                width: cellRect.width,
                height: height
            )
            cursorLayer.backgroundColor = color.cgColor
        }
    }

    private func updateCursorBlink(isBlinking: Bool) {
        if isBlinking {
            if cursorLayer.animation(forKey: "blink") == nil {
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 1
                blink.toValue = 0.15
                blink.duration = 0.6
                blink.autoreverses = true
                blink.repeatCount = .infinity
                cursorLayer.add(blink, forKey: "blink")
            }
        } else {
            cursorLayer.removeAnimation(forKey: "blink")
            cursorLayer.opacity = 1
        }
    }

    private func backgroundColorForCurrentFrame() -> UIColor {
        color(
            state.frame?.terminalBackground,
            fallback: color(TerminalThemeStore.current.background, fallback: .black)
        )
    }

    private func color(_ value: String?, fallback: UIColor) -> UIColor {
        guard let rgb = TerminalTheme.rgbComponents(value) else { return fallback }
        return UIColor(
            red: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }
}
#endif
