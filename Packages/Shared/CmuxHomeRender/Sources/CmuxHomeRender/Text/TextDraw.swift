import CoreGraphics
import CoreText
import Foundation

/// System fonts by size and weight (the UIKit/AppKit weight values).
enum Fonts {
    enum Weight: CGFloat, Sendable {
        case regular = 0, medium = 0.23, semibold = 0.3, bold = 0.4
    }

    static func system(_ size: CGFloat, _ weight: Weight = .regular) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard weight != .regular else { return base }
        let traits = [kCTFontWeightTrait: weight.rawValue] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base),
                                                                  [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// The font with extra symbolic traits (bold mention runs).
    static func withTraits(_ font: CTFont, _ traits: CTFontSymbolicTraits) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) ?? font
    }
}

/// Lines of text at explicit baselines with Core Text, in top-left contexts.
enum TextDraw {
    static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
    static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)

    static func attributes(_ font: CTFont, _ color: CGColor?, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [fontKey: font, kernKey: kern]
        if let color { a[colorKey] = color }
        return a
    }

    static func line(_ s: String, font: CTFont, color: CGColor, x: CGFloat, baseline: CGFloat, in ctx: CGContext,
                     kern: CGFloat = 0) {
        let attr = NSAttributedString(string: s, attributes: attributes(font, color, kern: kern))
        draw(CTLineCreateWithAttributedString(attr), x: x, baseline: baseline, ctx)
    }

    static func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func width(_ s: String, font: CTFont, kern: CGFloat = 0) -> CGFloat {
        let attr = NSAttributedString(string: s, attributes: attributes(font, nil, kern: kern))
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
    }
}
