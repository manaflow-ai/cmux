import CmuxFoundation
import CoreGraphics
import CoreText
import Foundation

/// Turns one captured window image into one encoded frame: crop, fit to the
/// clip's frame size, and draw the caption an agent asked for.
///
/// CoreText rather than AppKit text drawing, because frames are composed on the
/// recorder's own executor rather than the main actor.
enum WindowRecordingFrameComposer {
    static func compose(
        source: CGImage,
        geometry: WindowRecordingFrameGeometry,
        caption: String?
    ) -> CGImage? {
        guard geometry.outputWidth > 0, geometry.outputHeight > 0 else { return nil }
        let cropped = crop(source, to: geometry) ?? source
        guard let context = CGContext(
            data: nil,
            width: geometry.outputWidth,
            height: geometry.outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(geometry.outputWidth),
            height: CGFloat(geometry.outputHeight)
        )
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(bounds)
        context.draw(cropped, in: Self.fit(CGSize(
            width: CGFloat(cropped.width),
            height: CGFloat(cropped.height)
        ), in: bounds))
        if let caption, !caption.isEmpty {
            drawCaption(caption, in: context, bounds: bounds)
        }
        return context.makeImage()
    }

    private static func crop(
        _ source: CGImage,
        to geometry: WindowRecordingFrameGeometry
    ) -> CGImage? {
        guard !geometry.cropsNothing
            || geometry.cropWidth != source.width
            || geometry.cropHeight != source.height else {
            return source
        }
        let rect = CGRect(
            x: CGFloat(geometry.cropX),
            y: CGFloat(geometry.cropY),
            width: CGFloat(geometry.cropWidth),
            height: CGFloat(geometry.cropHeight)
        ).intersection(CGRect(
            x: 0,
            y: 0,
            width: CGFloat(source.width),
            height: CGFloat(source.height)
        ))
        guard !rect.isEmpty else { return nil }
        return source.cropping(to: rect)
    }

    /// Centers the captured content without distorting it. The two sizes match
    /// for the whole clip unless the window was resized while recording.
    ///
    /// A window that shrank keeps its own pixel size inside the frame instead of
    /// being magnified: blurry text in the middle of a clip reads as a rendering
    /// bug, while a black border reads as the window having been resized.
    static func fit(_ content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return bounds }
        let scale = min(1, min(bounds.width / content.width, bounds.height / content.height))
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: bounds.minX + ((bounds.width - size.width) / 2).rounded(),
            y: bounds.minY + ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    private static func drawCaption(
        _ caption: String,
        in context: CGContext,
        bounds: CGRect
    ) {
        let fontSize = max(12, bounds.height / 42)
        let margin = max(8, bounds.height / 60)
        let padding = max(5, bounds.height / 110)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 1, alpha: 1),
        ]
        let available = bounds.width - (margin * 2) - (padding * 2)
        guard available > fontSize else { return }
        var line = CTLineCreateWithAttributedString(
            NSAttributedString(string: caption, attributes: attributes)
        )
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(available) {
            let token = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\u{2026}", attributes: attributes)
            )
            line = CTLineCreateTruncatedLine(line, Double(available), .end, token) ?? line
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let box = CGRect(
            x: margin,
            y: margin,
            width: min(textWidth + (padding * 2), bounds.width - (margin * 2)),
            height: ascent + descent + (padding * 2)
        )
        context.saveGState()
        context.setFillColor(gray: 0, alpha: 0.66)
        context.addPath(CGPath(
            roundedRect: box,
            cornerWidth: padding,
            cornerHeight: padding,
            transform: nil
        ))
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: box.minX + padding, y: box.minY + padding + descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
