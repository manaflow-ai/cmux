import CoreGraphics
import CoreText
import Foundation

public enum CodexTrajectoryDrawingCoordinates: Sendable {
    case yUp
    case yDown
}

public struct CodexTrajectoryRenderer {
    public init() {}

    public func draw(
        block: CodexTrajectoryBlock,
        page: CodexTrajectoryLayoutPage,
        in context: CGContext,
        rect: CGRect,
        theme: CodexTrajectoryTheme,
        coordinates: CodexTrajectoryDrawingCoordinates = .yUp
    ) {
        let style = theme.style(for: block.kind)
        if let backgroundColor = style.backgroundColor {
            context.saveGState()
            context.setFillColor(backgroundColor)
            context.fill(rect)
            context.restoreGState()
        }

        let renderedPage = codexTrajectoryRenderedPage(for: block, page: page, theme: theme)
        guard !renderedPage.plainText.isEmpty else { return }

        switch coordinates {
        case .yUp:
            drawYUp(
                attributed: renderedPage.attributedString,
                in: context,
                textRect: rect.inset(by: theme.contentInsets(for: block.kind))
            )
        case .yDown:
            drawYDown(
                attributed: renderedPage.attributedString,
                in: context,
                rect: rect,
                insets: theme.contentInsets(for: block.kind)
            )
        }
    }

    private func drawYUp(
        attributed: CFAttributedString,
        in context: CGContext,
        textRect: CGRect
    ) {
        context.saveGState()
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGMutablePath()
        path.addRect(textRect)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func drawYDown(
        attributed: CFAttributedString,
        in context: CGContext,
        rect: CGRect,
        insets: CodexTrajectoryInsets
    ) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)

        let localTextRect = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: max(0, rect.width - insets.left - insets.right),
            height: max(0, rect.height - insets.top - insets.bottom)
        )
        drawYUp(attributed: attributed, in: context, textRect: localTextRect)
        context.restoreGState()
    }
}
