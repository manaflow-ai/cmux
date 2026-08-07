#if canImport(UIKit)
import CoreGraphics

/// Maps Ghostty's row-based viewport onto UIKit's point-based scroll range.
struct TerminalNativeScrollGeometry: Equatable, Sendable {
    struct Boundary: Equatable, Sendable {
        let totalRows: UInt64
        let viewportOffsetRows: UInt64
        let visibleRows: UInt64
    }

    struct Sample: Equatable, Sendable {
        let effectiveOffsetY: CGFloat
        let rowDelta: Double
        let contentTranslationY: CGFloat
    }

    let totalRows: UInt64
    let viewportOffsetRows: UInt64
    let visibleRows: UInt64
    let cellHeight: CGFloat
    let viewportHeight: CGFloat

    var maximumRowOffset: UInt64 {
        totalRows > visibleRows ? totalRows - visibleRows : 0
    }

    var maximumContentOffsetY: CGFloat {
        CGFloat(maximumRowOffset) * cellHeight
    }

    var contentHeight: CGFloat {
        viewportHeight + maximumContentOffsetY
    }

    var authoritativeContentOffsetY: CGFloat {
        CGFloat(min(viewportOffsetRows, maximumRowOffset)) * cellHeight
    }

    func sample(rawOffsetY: CGFloat, previousEffectiveOffsetY: CGFloat) -> Sample {
        let effectiveOffsetY = min(max(rawOffsetY, 0), maximumContentOffsetY)
        let deltaY = effectiveOffsetY - previousEffectiveOffsetY
        return Sample(
            effectiveOffsetY: effectiveOffsetY,
            rowDelta: cellHeight > 0 ? -Double(deltaY / cellHeight) : 0,
            contentTranslationY: -(rawOffsetY - effectiveOffsetY)
        )
    }
}
#endif
