import CoreGraphics
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The composer's one row, as the ChatGPT iOS app combines it (Leo, 2026-11-23: "as for the
/// composer, let's just unify it. like how the chatgpt one has it combined."): `+` at the left,
/// the text between, the picker and Send at the right, all on one line while the draft fits on
/// one line there. A draft that wraps takes the card's whole width above the same controls, with
/// the controls where they were (`+` bottom left, Send bottom right), so nothing jumps sideways.
///
/// The decision reads only the draft's height at the inline width, never the layout it is in, so
/// it cannot flip back and forth: a draft that wraps at the inline width stays on two rows until
/// it fits that width again.
public struct ComposerRowGeometry: Equatable, Sendable {
    /// Space between the controls and the text on the inline row.
    public static let spacing: CGFloat = 4
    /// The narrowest text the inline row keeps; narrower (a large text size, a long model name)
    /// and the draft goes above the controls.
    public static let minInlineFieldWidth: CGFloat = 96
    /// On two rows: the text's inset from the card's controls row edges (the text lines up with
    /// the `+` glyph's circle), its top inset, and the space between it and the controls.
    public static let textInset: CGFloat = 8
    public static let textTop: CGFloat = 11
    public static let textToControls: CGFloat = 2
    /// The controls row's least height: their 44 pt touch targets (the circles they draw are
    /// 36 pt and report that size, the targets reaching past it).
    public static let minRowHeight: CGFloat = 44

    public var inline: Bool
    public var size: CGSize
    public var leading: CGRect
    public var field: CGRect
    public var trailing: CGRect

    /// - Parameters:
    ///   - width: the row's width.
    ///   - leading, trailing: the controls' sizes.
    ///   - fieldHeight: the draft's height at a given width.
    ///   - lineHeight: one line of the draft's font.
    public static func place(width: CGFloat, leading: CGSize, trailing: CGSize,
                             fieldHeight: (CGFloat) -> CGFloat, lineHeight: CGFloat) -> ComposerRowGeometry {
        let row = max(minRowHeight, leading.height, trailing.height)
        let inlineWidth = width - leading.width - trailing.width - 2 * spacing
        let inlineHeight = inlineWidth >= minInlineFieldWidth ? fieldHeight(inlineWidth) : .infinity
        let leadingFrame = { (top: CGFloat) in
            CGRect(x: 0, y: top + (row - leading.height) / 2, width: leading.width, height: leading.height)
        }
        let trailingFrame = { (top: CGFloat) in
            CGRect(x: width - trailing.width, y: top + (row - trailing.height) / 2, width: trailing.width, height: trailing.height)
        }
        if inlineHeight <= lineHeight * 1.5 {
            let field = CGRect(x: leading.width + spacing, y: (row - inlineHeight) / 2, width: inlineWidth, height: inlineHeight)
            return ComposerRowGeometry(inline: true, size: CGSize(width: width, height: row),
                                       leading: leadingFrame(0), field: field, trailing: trailingFrame(0))
        }
        let fieldWidth = max(0, width - 2 * textInset)
        let height = fieldHeight(fieldWidth)
        let controlsTop = textTop + height + textToControls
        return ComposerRowGeometry(inline: false, size: CGSize(width: width, height: controlsTop + row),
                                   leading: leadingFrame(controlsTop),
                                   field: CGRect(x: textInset, y: textTop, width: fieldWidth, height: height),
                                   trailing: trailingFrame(controlsTop))
    }
}

#if canImport(SwiftUI)
/// Lays out exactly three subviews, leading controls, the field and trailing controls, by
/// ``ComposerRowGeometry``.
public struct ComposerRowLayout: Layout {
    /// One line of the field's font.
    public var lineHeight: CGFloat

    public init(lineHeight: CGFloat) { self.lineHeight = lineHeight }

    private func geometry(_ width: CGFloat?, _ subviews: Subviews) -> ComposerRowGeometry? {
        guard subviews.count == 3 else { return nil }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let field = subviews[1]
        let width = width ?? (leading.width + trailing.width + 2 * ComposerRowGeometry.spacing
            + max(ComposerRowGeometry.minInlineFieldWidth, field.sizeThatFits(.unspecified).width))
        return ComposerRowGeometry.place(width: width, leading: leading, trailing: trailing,
                                         fieldHeight: { field.sizeThatFits(ProposedViewSize(width: $0, height: nil)).height },
                                         lineHeight: lineHeight)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        geometry(proposal.width, subviews)?.size ?? .zero
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let geometry = geometry(bounds.width, subviews) else { return }
        for (index, frame) in [geometry.leading, geometry.field, geometry.trailing].enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
#endif
