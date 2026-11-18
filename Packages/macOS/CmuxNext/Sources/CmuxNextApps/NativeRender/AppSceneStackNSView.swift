import AppKit
import CmuxNextDesign

/// `VStack`, `LazyVStack`, `Group`, `ForEach`, `Reorderable` (vertical) and `HStack` (horizontal).
/// Vertical: each child fills the width, or keeps its natural width at the stack's `alignment`; the
/// height is the sum plus `spacing`. Horizontal: children keep their natural widths, filling children
/// share what is left (spacers last), text shrinks when the row is too narrow (lowest `layoutPriority` first,
/// never a `fixedSize` text), and each child sits at the row's `alignment` (`top`, `bottom`; centered by default)
/// on the row's height, or with `firstTextBaseline` / `lastTextBaseline` on one shared text baseline (a child
/// with no text aligns its bottom there, as in SwiftUI: AM/PM beside a big time). A section is a short list (budget 4096 nodes), so every child is laid out:
/// `LazyVStack` draws as a `VStack`.
final class AppSceneStackNSView: AppSceneNodeNSView {
    private var isHorizontal: Bool { node.type == .hStack }
    private var spacing: CGFloat { node.number("spacing").map { CGFloat($0) } ?? (isHorizontal ? Metrics.space2 : 0) }

    override var contentNaturalWidth: CGFloat? {
        guard isHorizontal else { return nil }
        var total = spacing * CGFloat(max(0, childViews.count - 1))
        for child in childViews {
            guard !child.isSpacer, let width = child.naturalWidth else { return nil }
            total += width
        }
        return total
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        guard !childViews.isEmpty else { return 0 }
        if isHorizontal {
            let childWidths = widths(for: width)
            if let placed = baselinePlacement(childWidths) { return placed.height }
            return zip(childViews, childWidths).map { $0.height(width: $1) }.max() ?? 0
        }
        return childViews.reduce(0) { $0 + $1.height(width: width) } + spacing * CGFloat(childViews.count - 1)
    }

    override func layoutContent(in rect: CGRect) {
        if isHorizontal {
            var x = rect.minX
            let childWidths = widths(for: rect.width)
            let placed = baselinePlacement(childWidths)
            for (index, (child, width)) in zip(childViews, childWidths).enumerated() {
                let height = child.height(width: width)
                // `alignment` top, center (the default), bottom or a text baseline, as SwiftUI's HStack (the view is flipped).
                let y: CGFloat = if let placed { rect.minY + placed.tops[index] } else {
                    switch node.string("alignment") {
                    case "top": rect.minY
                    case "bottom": rect.maxY - height
                    default: rect.minY + (rect.height - height) / 2
                    }
                }
                child.frame = CGRect(x: x, y: y, width: width, height: height).integral
                x += width + spacing
            }
            return
        }
        var y = rect.minY
        for child in childViews {
            let width = min(child.naturalWidth ?? rect.width, rect.width)
            let x: CGFloat = switch node.string("alignment") {
            case "center": rect.minX + (rect.width - width) / 2
            case "trailing": rect.maxX - width
            default: rect.minX
            }
            let height = child.height(width: width)
            child.frame = CGRect(x: x, y: y, width: width, height: height)
            y += height + spacing
        }
    }

    /// With `firstTextBaseline` or `lastTextBaseline`: each child's top below the row's top, so every
    /// child's baseline (its bottom when it has no text) is on one line, and the row's height.
    private func baselinePlacement(_ widths: [CGFloat]) -> (tops: [CGFloat], height: CGFloat)? {
        let last: Bool
        switch node.string("alignment") {
        case "firstTextBaseline": last = false
        case "lastTextBaseline": last = true
        default: return nil
        }
        let measured = zip(childViews, widths).map { child, width -> (height: CGFloat, baseline: CGFloat) in
            let height = child.height(width: width)
            let baseline = last
                ? height - (child.lastBaselineFromBottom(width: width) ?? 0)
                : child.firstBaseline(width: width) ?? height
            return (height, baseline)
        }
        let line = measured.map(\.baseline).max() ?? 0
        let tops = measured.map { line - $0.baseline }
        let height = zip(tops, measured).map { $0 + $1.height }.max() ?? 0
        return (tops, height)
    }

    override func firstBaseline(width: CGFloat) -> CGFloat? {
        let p = padding
        let inner = max(0, width - p.left - p.right)
        if isHorizontal {
            guard let placed = baselinePlacement(widths(for: inner)), node.string("alignment") == "firstTextBaseline" else { return nil }
            let childWidths = widths(for: inner)
            for (index, child) in childViews.enumerated() {
                if let baseline = child.firstBaseline(width: childWidths[index]) { return p.top + placed.tops[index] + baseline }
            }
            return nil
        }
        guard let first = childViews.first else { return nil }
        return first.firstBaseline(width: min(first.naturalWidth ?? inner, inner)).map { $0 + p.top }
    }

    override func lastBaselineFromBottom(width: CGFloat) -> CGFloat? {
        guard !isHorizontal, let last = childViews.last else { return nil }
        let p = padding
        let inner = max(0, width - p.left - p.right)
        return last.lastBaselineFromBottom(width: min(last.naturalWidth ?? inner, inner)).map { $0 + p.bottom }
    }

    /// The horizontal stack's child widths in `width`.
    private func widths(for width: CGFloat) -> [CGFloat] {
        let natural = childViews.map { $0.isSpacer ? nil : $0.naturalWidth }
        let fixed = natural.compactMap { $0 }.reduce(0, +)
        var left = width - fixed - spacing * CGFloat(max(0, childViews.count - 1))
        var out = natural.map { $0 ?? 0 }
        let fillers = childViews.indices.filter { natural[$0] == nil && !childViews[$0].isSpacer }
        let spacers = childViews.indices.filter { childViews[$0].isSpacer }
        if left >= 0 {
            let takers = fillers.isEmpty ? spacers : fillers
            for index in takers { out[index] = left / CGFloat(takers.count) }
            return out
        }
        // Too narrow: text gives up width, never below zero: the lowest `layoutPriority` first, then from the last one
        // back; a text with `fixedSize` "horizontal" (or "both") keeps its width.
        let givers = childViews.indices.reversed().filter { childViews[$0] is AppSceneTextNSView && !Self.keepsWidth(childViews[$0].node) }
        let ordered = givers.enumerated().sorted { a, b in
            let (pa, pb) = (childViews[a.element].node.number("layoutPriority") ?? 0, childViews[b.element].node.number("layoutPriority") ?? 0)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
        for index in ordered where left < 0 {
            let give = min(out[index], -left)
            out[index] -= give
            left += give
        }
        return out
    }

    /// Whether a text keeps its natural width in a row that is too narrow (`fixedSize` "horizontal" or "both").
    private static func keepsWidth(_ node: AppSceneNode) -> Bool {
        switch node.string("fixedSize") {
        case "horizontal", "both": true
        default: false
        }
    }
}
