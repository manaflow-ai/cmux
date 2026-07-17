#if canImport(UIKit)
import CMUXMobileCore
import UIKit

/// Draws one immutable producer-authored grid using absolute terminal cells.
///
/// Render-grid v1 carries one font size and boolean style flags, so this UIKit
/// renderer approximates Ghostty font faces, blinking text, and underline
/// variants. The wire format does not carry hyperlink identities or terminal
/// image payloads. Ghostty semantic consumers fail closed while this view owns
/// presentation because a pixel grid is not sufficient to reconstruct parser state.
@MainActor
final class AuthoritativeTerminalGridView: UIView {
    private static let blinkInterval: CFTimeInterval = 0.6
    private var state: AuthoritativeTerminalGridState
    private let cursorLayer = CAShapeLayer()
    private var blinkOrigin: CFTimeInterval
    private var textBlinkPhaseVisible = true
    private var cursorBlinkPhaseVisible = true
    private var hasBlinkingText = false
    private var hasBlinkingCursor = false
    var terminalTheme: TerminalTheme = .monokai {
        didSet {
            guard terminalTheme != oldValue else { return }
            setNeedsDisplay()
            setNeedsLayout()
        }
    }
    var terminalFontSize: CGFloat = 10 {
        didSet {
            guard terminalFontSize != oldValue else { return }
            setNeedsDisplay()
        }
    }

    init(surfaceID: String) {
        self.state = AuthoritativeTerminalGridState(surfaceID: surfaceID)
        self.blinkOrigin = CACurrentMediaTime()
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
        let result = state.commit(frame)
        guard result == .presented else { return result }
        let styleIDsWithBlink = Set(frame.styles.lazy.filter(\.blink).map(\.id))
        hasBlinkingText = frame.rowSpans.contains { styleIDsWithBlink.contains($0.styleID) }
        hasBlinkingCursor = frame.cursor?.blinking == true
        setNeedsDisplay()
        setNeedsLayout()
        return result
    }

    func classify(
        _ frame: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        state.classify(frame)
    }

    func beginReplay(surfaceID: String) {
        state.beginReplay(surfaceID: surfaceID)
    }

    func clear(surfaceID: String) {
        state.replaceSurface(surfaceID: surfaceID)
        textBlinkPhaseVisible = true
        cursorBlinkPhaseVisible = true
        hasBlinkingText = false
        hasBlinkingCursor = false
        blinkOrigin = CACurrentMediaTime()
        cursorLayer.isHidden = true
        setNeedsDisplay()
    }

    func advanceBlink(now: CFTimeInterval) {
        guard let frame = state.frame else { return }
        let phaseVisible = Int(max(0, now - blinkOrigin) / Self.blinkInterval).isMultiple(of: 2)
        let textChanged = hasBlinkingText && textBlinkPhaseVisible != phaseVisible
        let cursorChanged = hasBlinkingCursor && cursorBlinkPhaseVisible != phaseVisible
        textBlinkPhaseVisible = phaseVisible
        cursorBlinkPhaseVisible = phaseVisible
        if textChanged || (cursorChanged && frame.cursor?.style == .block) {
            setNeedsDisplay()
        }
        if cursorChanged {
            updateCursorLayer()
        }
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

        let theme = renderTheme(for: frame)
        let frameDefaultStyle = frame.styles.first(where: { $0.id == 0 })
        let defaultBackground = color(
            frameDefaultStyle?.background ?? frame.terminalBackground,
            fallback: color(theme.background, fallback: .black)
        )
        let defaultForeground = color(
            frameDefaultStyle?.foreground ?? frame.terminalForeground,
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
        drawBlockCursor(
            frame: frame,
            stylesByID: stylesByID,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            context: context
        )
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
        environment: SpanDrawingEnvironment,
        foregroundOverride: UIColor? = nil,
        drawsBackground: Bool = true
    ) {
        let resolved = resolvedColors(for: style, environment: environment)
        let foreground = foregroundOverride ?? resolved.foreground
        if drawsBackground, let background = resolved.background {
            environment.context.setFillColor(background.cgColor)
            environment.context.fill(environment.rect)
        }
        guard !style.invisible,
              !span.text.isEmpty,
              Self.shouldDrawText(
                styleBlinks: style.blink,
                blinkPhaseVisible: textBlinkPhaseVisible
              ) else { return }
        let font = font(for: style, cellHeight: environment.cellHeight)
        let attributes = textAttributes(for: style, font: font, foreground: foreground)
        drawText(span.text, font: font, attributes: attributes, environment: environment)
        if style.overline {
            drawOverline(color: foreground, environment: environment)
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
        foreground = foreground.withAlphaComponent(style.foregroundOpacity)
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
              (!cursor.blinking || cursorBlinkPhaseVisible),
              frame.columns > 0,
              frame.rows > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let cellWidth = bounds.width / CGFloat(frame.columns)
        let cellHeight = bounds.height / CGFloat(frame.rows)
        let cellRect = CGRect(
            x: CGFloat(cursor.column) * cellWidth,
            y: CGFloat(cursor.row) * cellHeight,
            width: CGFloat(cursor.cellWidth) * cellWidth,
            height: cellHeight
        )
        let frameDefaultForeground = frame.styles.first(where: { $0.id == 0 })?.foreground
        let cursorColor = color(
            frame.terminalCursorColor ?? frameDefaultForeground,
            fallback: color(renderTheme(for: frame).cursor, fallback: .white)
        )
        guard cursor.style != .block else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.isHidden = false
        cursorLayer.borderColor = nil
        cursorLayer.borderWidth = 0
        applyCursorStyle(
            cursor.style,
            cellRect: cellRect,
            singleCellWidth: cellWidth,
            color: cursorColor.withAlphaComponent(cursor.opacity)
        )
    }

    private func applyCursorStyle(
        _ style: MobileTerminalRenderGridFrame.Cursor.Style,
        cellRect: CGRect,
        singleCellWidth: CGFloat,
        color: UIColor
    ) {
        switch style {
        case .block:
            cursorLayer.isHidden = true
        case .blockHollow:
            cursorLayer.frame = cellRect.insetBy(dx: 0.5, dy: 0.5)
            cursorLayer.backgroundColor = UIColor.clear.cgColor
            cursorLayer.borderColor = color.cgColor
            cursorLayer.borderWidth = max(1 / max(contentScaleFactor, 1), 1)
        case .bar:
            cursorLayer.frame = CGRect(
                x: cellRect.minX,
                y: cellRect.minY,
                width: max(1 / max(contentScaleFactor, 1), singleCellWidth * 0.12),
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

    private func drawBlockCursor(
        frame: MobileTerminalRenderGridFrame,
        stylesByID: [Int: MobileTerminalRenderGridFrame.Style],
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        defaultForeground: UIColor,
        defaultBackground: UIColor,
        context: CGContext
    ) {
        guard let cursor = frame.cursor,
              cursor.visible,
              cursor.style == .block,
              !cursor.blinking || cursorBlinkPhaseVisible else { return }
        let cursorRect = CGRect(
            x: CGFloat(cursor.column) * cellWidth,
            y: CGFloat(cursor.row) * cellHeight,
            width: CGFloat(cursor.cellWidth) * cellWidth,
            height: cellHeight
        )
        let defaultStyle = frame.styles.first(where: { $0.id == 0 })
        let theme = renderTheme(for: frame)
        let cursorColor = color(
            frame.terminalCursorColor ?? defaultStyle?.foreground,
            fallback: color(theme.cursor, fallback: defaultForeground)
        ).withAlphaComponent(cursor.opacity)
        let cursorTextColor = color(
            frame.terminalCursorTextColor ?? theme.cursorText,
            fallback: defaultBackground
        )
        context.setFillColor(cursorColor.cgColor)
        context.fill(cursorRect)

        context.saveGState()
        context.clip(to: cursorRect)
        for span in frame.rowSpans where span.row == cursor.row {
            let spanRect = CGRect(
                x: CGFloat(span.column) * cellWidth,
                y: CGFloat(span.row) * cellHeight,
                width: CGFloat(span.gridCellWidth) * cellWidth,
                height: cellHeight
            )
            guard spanRect.intersects(cursorRect) else { continue }
            draw(
                span: span,
                style: stylesByID[span.styleID] ?? .default,
                environment: SpanDrawingEnvironment(
                    rect: spanRect,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    defaultForeground: defaultForeground,
                    defaultBackground: defaultBackground,
                    context: context
                ),
                foregroundOverride: cursorTextColor,
                drawsBackground: false
            )
        }
        context.restoreGState()
    }

    private func backgroundColorForCurrentFrame() -> UIColor {
        let frame = state.frame
        let frameDefaultBackground = frame?.styles.first(where: { $0.id == 0 })?.background
        return color(
            frameDefaultBackground ?? frame?.terminalBackground,
            fallback: color(renderTheme(for: frame).background, fallback: .black)
        )
    }

    private func renderTheme(for frame: MobileTerminalRenderGridFrame?) -> TerminalTheme {
        (frame?.terminalTheme ?? terminalTheme).validatedOrDefault()
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
