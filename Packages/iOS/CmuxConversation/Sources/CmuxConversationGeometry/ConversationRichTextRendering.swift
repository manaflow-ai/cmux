import CmuxConversationCore
import QuartzCore
#if canImport(UIKit)
import UIKit
public typealias ConversationPlatformFont = UIFont
public typealias ConversationPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias ConversationPlatformFont = NSFont
public typealias ConversationPlatformColor = NSColor
#endif

extension NSAttributedString.Key {
    /// The real foreground color of a glyph that an effect layer draws (the
    /// text view itself draws it clear).
    public static let conversationEffectInk = NSAttributedString.Key("cmuxConversationEffectInk")
}

/// Turns the semantic formatting keys into fonts and decorations, shared by
/// bubbles and composers on both platforms.
public enum ConversationRichTextStyler {
    /// Applies fonts, underline, strikethrough and effect sizing over
    /// `range` (default: all) of a string whose base font is `baseFont`.
    /// Effect glyphs are drawn clear; `ConversationTextEffectLayer` draws them.
    public static func applyDisplayAttributes(
        to string: NSMutableAttributedString,
        baseFont: ConversationPlatformFont,
        lineHeight: CGFloat,
        range: NSRange? = nil
    ) {
        let whole = range ?? NSRange(location: 0, length: string.length)
        guard whole.length > 0 else { return }
        string.enumerateAttributes(in: whole) { attributes, subrange, _ in
            let style = ConversationTextStyle(rawValue: attributes[.conversationTextStyle] as? Int ?? 0)
            let effect = (attributes[.conversationTextEffect] as? String).flatMap(ConversationTextEffect.init(rawValue:))
            let size = baseFont.pointSize * CGFloat(effect.map(ConversationTextEffectMotion.fontScale) ?? 1)
            string.addAttribute(.font, value: font(base: baseFont, size: size, style: style), range: subrange)
            // Run before link detection: links add their own underline afterwards.
            if style.contains(.underline) {
                string.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: subrange)
            } else {
                string.removeAttribute(.underlineStyle, range: subrange)
            }
            if style.contains(.strikethrough) {
                string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: subrange)
            } else {
                string.removeAttribute(.strikethroughStyle, range: subrange)
            }
            if effect != nil {
                let ink = attributes[.conversationEffectInk] ?? attributes[.foregroundColor] ?? ConversationPlatformColor.black
                string.addAttribute(.conversationEffectInk, value: ink, range: subrange)
                string.addAttribute(.foregroundColor, value: ConversationPlatformColor.clear, range: subrange)
            } else if let ink = attributes[.conversationEffectInk] {
                string.addAttribute(.foregroundColor, value: ink, range: subrange)
                string.removeAttribute(.conversationEffectInk, range: subrange)
            }
        }
        relaxLineHeights(in: string, lineHeight: lineHeight, baseFont: baseFont)
    }

    public static func font(base: ConversationPlatformFont, size: CGFloat, style: ConversationTextStyle) -> ConversationPlatformFont {
        #if canImport(UIKit)
        var traits = base.fontDescriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size)
        #else
        var traits = base.fontDescriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.bold) }
        if style.contains(.italic) { traits.insert(.italic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
        #endif
    }

    /// The theme pins every line to `lineHeight`; a paragraph holding Big text
    /// needs taller lines (and Small text keeps the base pitch).
    private static func relaxLineHeights(in string: NSMutableAttributedString, lineHeight: CGFloat, baseFont: ConversationPlatformFont) {
        let text = string.string as NSString
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            var scale: CGFloat = 1
            string.enumerateAttribute(.conversationTextEffect, in: paragraph) { value, _, _ in
                if let raw = value as? String, let effect = ConversationTextEffect(rawValue: raw) {
                    scale = max(scale, CGFloat(ConversationTextEffectMotion.fontScale(effect)))
                }
            }
            if let existing = string.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
               existing.minimumLineHeight > 0 {
                let target = scale > 1 ? ceil(lineHeight * scale) : lineHeight
                if existing.minimumLineHeight != target || existing.maximumLineHeight != target {
                    let style = (existing.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    style.minimumLineHeight = target
                    style.maximumLineHeight = target
                    string.addAttribute(.paragraphStyle, value: style, range: paragraph)
                }
            }
            location = NSMaxRange(paragraph)
        }
    }

    public static func hasEffects(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.conversationTextEffect, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
}

/// Draws the effect glyphs of a styled string as one sublayer per glyph (per
/// word for long runs) and animates them with `ConversationTextEffectMotion`.
/// Sits exactly over the text view that drew everything else; its own
/// coordinate space is top-left-origin with the text at `textOrigin`.
public final class ConversationTextEffectLayer: CALayer {
    private struct Unit {
        var range: NSRange
        var rect: CGRect
        var effect: ConversationTextEffect
        var index: Int
        var count: Int
    }

    private var signature: (text: NSAttributedString, size: CGSize, origin: CGPoint, scale: CGFloat, animated: Bool)?
    /// Above this many characters in one run, words move instead of letters.
    public var maximumGlyphUnits = 80

    public override init() {
        super.init()
    }

    public override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    private static let flipSign: CGFloat = 1

    /// The effect math is top-left-origin. UIKit trees already are; in AppKit
    /// the tree is bottom-left unless a flipped view's layer flipped it, so
    /// flip this layer exactly when its ancestors leave it bottom-left.
    private func orientTopLeft() {
        #if !canImport(UIKit)
        var flippedAncestors = false
        var ancestor = superlayer
        while let layer = ancestor {
            if layer.isGeometryFlipped { flippedAncestors.toggle() }
            ancestor = layer.superlayer
        }
        if isGeometryFlipped == flippedAncestors { isGeometryFlipped = !flippedAncestors }
        #endif
    }

    public override func action(forKey event: String) -> (any CAAction)? { NSNull() }

    /// Lays out and renders the effect glyphs of `text` (laid out in
    /// `textSize` with line fragment padding 0) and starts their loop.
    /// `seed` keys explode/jitter randomness. Re-calls with the same input keep
    /// the running animation.
    public func update(text: NSAttributedString, textSize: CGSize, textOrigin: CGPoint = .zero, scale: CGFloat, animated: Bool, seed: UInt64, restart: Bool = false) {
        if !restart, let signature, signature.size == textSize, signature.origin == textOrigin, signature.scale == scale,
           signature.animated == animated, signature.text.isEqual(to: text) {
            return
        }
        signature = (NSAttributedString(attributedString: text), textSize, textOrigin, scale, animated)
        orientTopLeft()
        sublayers?.forEach { $0.removeFromSuperlayer() }
        guard ConversationRichTextStyler.hasEffects(text), textSize.width > 0 else { return }
        let units = Self.units(in: text, size: textSize, maximumGlyphUnits: maximumGlyphUnits)
        let begin = CACurrentMediaTime()
        for unit in units {
            guard let font = text.attribute(.font, at: unit.range.location, effectiveRange: nil) as? ConversationPlatformFont else { continue }
            // Generous padding: italics overhang and motion scales the glyph.
            let pad = ceil(font.pointSize * 0.35)
            let box = unit.rect.insetBy(dx: -pad, dy: -pad).integral
            guard let image = Self.render(text, unit: unit.range, textSize: textSize, box: box, scale: scale) else { continue }
            let glyph = CALayer()
            glyph.contents = image
            glyph.contentsScale = scale
            glyph.frame = box.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
            glyph.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull()]
            addSublayer(glyph)
            if animated {
                glyph.add(Self.animation(unit, fontSize: font.pointSize, seed: seed, begin: begin), forKey: "cmux.textEffect")
            }
        }
    }

    public func clear() {
        signature = nil
        sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private static func units(in text: NSAttributedString, size: CGSize, maximumGlyphUnits: Int) -> [Unit] {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let nsString = text.string as NSString
        var units: [Unit] = []
        text.enumerateAttribute(.conversationTextEffect, in: NSRange(location: 0, length: text.length)) { value, runRange, _ in
            guard let raw = value as? String, let effect = ConversationTextEffect(rawValue: raw) else { return }
            var pieces: [NSRange] = []
            let byWord = runRange.length > maximumGlyphUnits
            nsString.enumerateSubstrings(in: runRange, options: byWord ? .byWords : .byComposedCharacterSequences) { substring, range, _, _ in
                guard let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                pieces.append(range)
            }
            for (index, range) in pieces.enumerated() {
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                // A word can wrap; union of its line fragments keeps it whole.
                var rect = CGRect.null
                manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
                    rect = rect.union(r)
                }
                guard !rect.isNull, rect.width > 0 else { continue }
                units.append(Unit(range: range, rect: rect, effect: effect, index: index, count: pieces.count))
            }
        }
        return units
    }

    /// The whole string drawn with only `unit` inked, cropped to `box`.
    private static func render(_ text: NSAttributedString, unit: NSRange, textSize: CGSize, box: CGRect, scale: CGFloat) -> CGImage? {
        let inked = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: inked.length)
        inked.addAttribute(.foregroundColor, value: ConversationPlatformColor.clear, range: whole)
        inked.enumerateAttribute(.conversationEffectInk, in: unit) { value, range, _ in
            if let value { inked.addAttribute(.foregroundColor, value: value, range: range) }
        }
        let width = Int(ceil(box.width * scale))
        let height = Int(ceil(box.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Top-left origin, points, with the box's corner at the origin.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        let drawRect = CGRect(origin: .zero, size: CGSize(width: textSize.width, height: max(textSize.height, box.maxY)))
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        inked.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
        #else
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        inked.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        NSGraphicsContext.current = previous
        #endif
        return context.makeImage()
    }

    private static func animation(_ unit: Unit, fontSize: CGFloat, seed: UInt64, begin: CFTimeInterval) -> CAAnimation {
        let cycle = ConversationTextEffectMotion.cycle
        let fps = 60.0
        let frames = Int(cycle * fps)
        var transforms: [NSValue] = []
        var opacities: [NSNumber] = []
        var times: [NSNumber] = []
        transforms.reserveCapacity(frames + 1)
        for frame in 0...frames {
            let t = Double(frame) / fps
            let pose = ConversationTextEffectMotion.pose(unit.effect, index: unit.index, count: unit.count, time: t, seed: seed)
            var transform = CATransform3DMakeTranslation(CGFloat(pose.dx) * fontSize, CGFloat(pose.dy) * fontSize * flipSign, 0)
            transform = CATransform3DRotate(transform, CGFloat(pose.rotation) * flipSign, 0, 0, 1)
            transform = CATransform3DScale(transform, CGFloat(pose.scale), CGFloat(pose.scale), 1)
            transforms.append(NSValue(caTransform3D: transform))
            opacities.append(NSNumber(value: pose.opacity))
            times.append(NSNumber(value: t / cycle))
        }
        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = transforms
        transform.keyTimes = times
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = opacities
        opacity.keyTimes = times
        let group = CAAnimationGroup()
        group.animations = [transform, opacity]
        group.duration = cycle
        group.repeatCount = .infinity
        group.beginTime = begin
        group.isRemovedOnCompletion = false
        return group
    }
}
