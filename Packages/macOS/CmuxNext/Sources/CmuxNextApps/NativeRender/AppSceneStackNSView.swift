import AppKit
import CmuxNextDesign

/// `VStack`, `LazyVStack`, `Group`, `ForEach`, `Reorderable` (vertical) and `HStack` (horizontal).
/// Vertical: each child fills the width, or keeps its natural width at the stack's `alignment`; the
/// height is the sum plus `spacing`. Horizontal: children keep their natural widths, filling children
/// share what is left (spacers last), text shrinks when the row is too narrow, and each child centers
/// on the row's height. A section is a short list (budget 4096 nodes), so every child is laid out:
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
            return zip(childViews, widths(for: width)).map { $0.height(width: $1) }.max() ?? 0
        }
        return childViews.reduce(0) { $0 + $1.height(width: width) } + spacing * CGFloat(childViews.count - 1)
    }

    override func layoutContent(in rect: CGRect) {
        if isHorizontal {
            var x = rect.minX
            for (child, width) in zip(childViews, widths(for: rect.width)) {
                let height = child.height(width: width)
                child.frame = CGRect(x: x, y: rect.minY + (rect.height - height) / 2, width: width, height: height).integral
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
        // Too narrow: text gives up width from the last one back, never below zero.
        for index in childViews.indices.reversed() where childViews[index] is AppSceneTextNSView && left < 0 {
            let give = min(out[index], -left)
            out[index] -= give
            left += give
        }
        return out
    }
}
