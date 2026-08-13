#if canImport(UIKit)
import UIKit

extension GhosttySurfaceView {
    func handleScrollPresentationAuthorityChange() {
        let usesPixelViewport = scrollPresentationAuthority.usesBoundedPixelViewport
        resetNativePixelScrollState(clearBoundary: !usesPixelViewport)
        if !usesPixelViewport {
            _ = applyLocalScrollbackPresentation(translationY: 0)
        }
    }

    func resetNativePixelScrollState(clearBoundary: Bool) {
        if clearBoundary {
            nativePixelScrollBoundary = nil
        }
        nativePixelScrollState = nil
        nativePixelScrollPresentedRow = nil
        nativePixelScrollCellHeight = 0
        nativePixelScrollLastRequestedRow = nil
        nativePixelScrollHasRequestedViewport = false
        nativePixelScrollIsConfiguring = false
    }

    /// Configures the transparent mechanics view as terminal row-space.
    ///
    /// - Parameters:
    ///   - scrollView: The native view supplying touch tracking and deceleration.
    ///   - preferredOffsetY: An authoritative offset to adopt, when appropriate.
    /// - Returns: `true` when bounded pixel scrolling owns the mechanics view.
    @discardableResult
    func configureNativePixelScrollRange(
        scrollView: UIScrollView,
        preferredOffsetY: CGFloat? = nil
    ) -> Bool {
        guard scrollPresentationAuthority.usesBoundedPixelViewport else {
            return false
        }

        let cellHeight = renderedCellSizeInPoints.height
        guard let boundary = nativePixelScrollBoundary,
              cellHeight > 0,
              scrollView.bounds.height > 0 else {
            nativePixelScrollIsConfiguring = true
            scrollView.contentSize = scrollView.bounds.size
            scrollView.contentOffset = .zero
            nativePixelScrollIsConfiguring = false
            return true
        }

        let maximumOffsetY = CGFloat(maximumNativePixelScrollRow(for: boundary)) * cellHeight
        let previousCellHeight = nativePixelScrollCellHeight
        let cellHeightChanged = previousCellHeight > 0
            && abs(previousCellHeight - cellHeight) > 0.001
        var targetOffsetY = scrollView.contentOffset.y
        if cellHeightChanged {
            targetOffsetY = targetOffsetY / previousCellHeight * cellHeight
        }
        if let preferredOffsetY {
            targetOffsetY = preferredOffsetY
        }
        targetOffsetY = min(max(targetOffsetY, 0), maximumOffsetY)

        let presentedRow = nativePixelScrollPresentedRow ?? boundary.viewportOffsetRows
        let authoritativeOffsetY = CGFloat(presentedRow) * cellHeight
        if nativePixelScrollState == nil || cellHeightChanged {
            nativePixelScrollState = TerminalPixelScrollState(
                initialOffsetY: authoritativeOffsetY
            )
        }
        nativePixelScrollCellHeight = cellHeight

        nativePixelScrollIsConfiguring = true
        scrollView.contentSize = CGSize(
            width: max(scrollView.bounds.width, 1),
            height: scrollView.bounds.height + maximumOffsetY
        )
        if abs(scrollView.contentOffset.y - targetOffsetY) > 0.001 {
            scrollView.contentOffset = CGPoint(x: 0, y: targetOffsetY)
        }
        nativePixelScrollIsConfiguring = false
        reconcileNativePixelScrollPresentation(scrollView: scrollView)
        return true
    }

    func handleNativePixelScrollBoundaryChange(_ boundary: TerminalScrollBoundary) {
        guard scrollPresentationAuthority.usesBoundedPixelViewport else { return }

        let previousMaximumOffsetY = nativePixelScrollBoundary.map {
            CGFloat(maximumNativePixelScrollRow(for: $0)) * nativePixelScrollCellHeight
        }
        let wasAtBottom = previousMaximumOffsetY.map {
            abs(currentNativePixelScrollOffsetY - $0) < 0.5
        } ?? false
        nativePixelScrollBoundary = boundary

        let hasPendingViewport = localViewportState.inFlight != nil
            || localViewportState.pendingRow != nil
        let shouldAdoptBoundary = !nativePixelScrollHasRequestedViewport
            || (wasAtBottom && !hasPendingViewport && !nativePixelScrollInteractionActive)
        let cellHeight = renderedCellSizeInPoints.height
        let authoritativeOffsetY = CGFloat(boundary.viewportOffsetRows) * cellHeight
        if shouldAdoptBoundary {
            nativePixelScrollPresentedRow = boundary.viewportOffsetRows
            nativePixelScrollState?.updateAuthoritativeOffsetY(authoritativeOffsetY)
        }
        _ = configureNativePixelScrollRange(
            scrollView: scrollMechanicsView,
            preferredOffsetY: shouldAdoptBoundary ? authoritativeOffsetY : nil
        )
    }

    func handleNativePixelScrollViewportPresented(row: UInt64) {
        guard scrollPresentationAuthority.usesBoundedPixelViewport else { return }
        nativePixelScrollPresentedRow = row
        nativePixelScrollState?.updateAuthoritativeOffsetY(
            CGFloat(row) * nativePixelScrollCellHeight
        )
        reconcileNativePixelScrollPresentation(scrollView: scrollMechanicsView)
    }

    /// Applies one native offset sample to Ghostty's row and renderer layers.
    ///
    /// - Parameter scrollView: The mechanics view whose offset changed.
    /// - Returns: `true` when the effective terminal position changed.
    func handleNativePixelScroll(scrollView: UIScrollView) -> Bool {
        guard scrollPresentationAuthority.usesBoundedPixelViewport,
              !nativePixelScrollIsConfiguring,
              var state = nativePixelScrollState,
              nativePixelScrollCellHeight > 0 else {
            return false
        }

        let previousOffsetY = state.effectiveOffsetY
        let maximumOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let sample = state.sample(
            rawOffsetY: scrollView.contentOffset.y,
            maximumOffsetY: maximumOffsetY,
            cellHeight: nativePixelScrollCellHeight
        )
        nativePixelScrollState = state

        if sample.effectiveOffsetY != previousOffsetY {
            // Every fractional UIKit movement is a newer viewport intent, even
            // when it rounds to the same Ghostty row. Live output must not
            // publish a competing row presentation during the tail of a drag
            // or deceleration, which is where adjacent-row stutter appears.
            bumpUserViewportInteractionGeneration()
        }
        if sample.targetViewportRow != nativePixelScrollLastRequestedRow {
            nativePixelScrollLastRequestedRow = sample.targetViewportRow
            nativePixelScrollHasRequestedViewport = true
            applyLocalScrollbackViewport(row: sample.targetViewportRow)
        }
        _ = applyLocalScrollbackPresentation(
            translationY: sample.presentationTranslationY
        )
        return sample.effectiveOffsetY != previousOffsetY
    }

    private func reconcileNativePixelScrollPresentation(scrollView: UIScrollView) {
        guard scrollPresentationAuthority.usesBoundedPixelViewport,
              var state = nativePixelScrollState,
              nativePixelScrollCellHeight > 0 else { return }
        let maximumOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let sample = state.sample(
            rawOffsetY: scrollView.contentOffset.y,
            maximumOffsetY: maximumOffsetY,
            cellHeight: nativePixelScrollCellHeight
        )
        nativePixelScrollState = state
        _ = applyLocalScrollbackPresentation(
            translationY: sample.presentationTranslationY
        )
    }

    private func maximumNativePixelScrollRow(
        for boundary: TerminalScrollBoundary
    ) -> UInt64 {
        boundary.totalRows > boundary.visibleRows
            ? boundary.totalRows - boundary.visibleRows
            : 0
    }

    private var currentNativePixelScrollOffsetY: CGFloat {
        scrollMechanicsView.contentOffset.y
    }

    /// UIKit owns the visible viewport for the whole gesture, including its
    /// deceleration tail. Live output may update row geometry during this
    /// window, but it must not replace the user's position with a boundary
    /// callback from Ghostty. Otherwise the boundary path becomes a second
    /// viewport writer while the native pixel presentation is still moving.
    private var nativePixelScrollInteractionActive: Bool {
        scrollMechanicsView.isTracking
            || scrollMechanicsView.isDragging
            || scrollMechanicsView.isDecelerating
    }
}
#endif
