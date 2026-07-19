#if os(iOS)
import UIKit

/// Deterministic scroll geometry for the workspace list's custom refresh presentation.
struct WorkspaceListRefreshGeometry: Equatable, Sendable {
    static let holdHeight: CGFloat = 56
    static let triggerDistance: CGFloat = 72

    let baseContentInset: UIEdgeInsets
    let adjustedContentInset: UIEdgeInsets
    let currentContentInset: UIEdgeInsets
    let contentOffset: CGPoint

    init(
        baseContentInset: UIEdgeInsets,
        adjustedContentInset: UIEdgeInsets,
        currentContentInset: UIEdgeInsets,
        contentOffset: CGPoint
    ) {
        self.baseContentInset = baseContentInset
        self.adjustedContentInset = adjustedContentInset
        self.currentContentInset = currentContentInset
        self.contentOffset = contentOffset
    }

    /// The adjusted top inset before the refresh presentation added its hold inset.
    var baseAdjustedTop: CGFloat {
        adjustedContentInset.top - extraTop
    }

    /// Distance pulled beyond the list's baseline resting position.
    var pullDistance: CGFloat {
        max(0, -(contentOffset.y + baseAdjustedTop))
    }

    /// Normalized progress toward the refresh trigger.
    var pullProgress: CGFloat {
        min(pullDistance / Self.triggerDistance, 1)
    }

    /// Whether releasing the current pull should begin a refresh.
    var isArmed: Bool {
        pullDistance >= Self.triggerDistance
    }

    /// The list's resting vertical offset without a refresh hold inset.
    var restingOffsetY: CGFloat {
        -baseAdjustedTop
    }

    /// The vertical offset that keeps the refresh header fully revealed.
    var heldOffsetY: CGFloat {
        restingOffsetY - Self.holdHeight
    }

    /// Temporary inset that makes the exact release offset a legal top edge.
    var releasePinHeight: CGFloat {
        max(pullDistance, Self.holdHeight)
    }

    /// The collapse destination, preserving an offset already below the resting position.
    var collapseTargetOffsetY: CGFloat {
        max(contentOffset.y, restingOffsetY)
    }

    private var extraTop: CGFloat {
        currentContentInset.top - baseContentInset.top
    }
}
#endif
