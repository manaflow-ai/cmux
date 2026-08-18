#if canImport(UIKit)
import CoreGraphics

/// Maps Ghostty's row-based viewport onto UIKit's point-based scroll range.
nonisolated struct TerminalNativeScrollGeometry: Equatable, Sendable {
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

    static func shouldSynchronize(
        explicitlyRequested: Bool,
        isInteracting: Bool,
        hasPendingScroll: Bool
    ) -> Bool {
        explicitlyRequested || (!isInteracting && !hasPendingScroll)
    }

    /// Fail-closed geometry for a confirmed primary screen whose authoritative
    /// boundary has not arrived yet: zero scrollable range, so gestures rubber
    /// band without emitting best-effort wheel deltas outside real history.
    static func zeroRange(cellHeight: CGFloat, viewportHeight: CGFloat) -> TerminalNativeScrollGeometry {
        TerminalNativeScrollGeometry(
            totalRows: 0,
            viewportOffsetRows: 0,
            visibleRows: 0,
            cellHeight: max(cellHeight, 1),
            viewportHeight: viewportHeight
        )
    }

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

    /// Pixel-smooth presentation for an interacting finger: the terminal grid
    /// renders whole rows only, so content is translated by the remainder
    /// between the finger's pixel position and the last authoritative row
    /// position. The in-range compensation is clamped to two rows so a lagging
    /// renderer can never drag content far from what it actually drew; the
    /// rubber-band component stays unclamped so overdrag tracks the finger.
    func presentationTranslation(rawOffsetY: CGFloat, effectiveOffsetY: CGFloat) -> CGFloat {
        let rubberBand = -(rawOffsetY - effectiveOffsetY)
        let limit = cellHeight * 2
        let fractional = min(max(authoritativeContentOffsetY - effectiveOffsetY, -limit), limit)
        return rubberBand + fractional
    }
}
#endif
