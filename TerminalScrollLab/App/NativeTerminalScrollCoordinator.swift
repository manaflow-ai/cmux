import CmuxMobileTerminal
import UIKit

/// Connects a native scroll view to the local Ghostty viewport.
@MainActor
final class NativeTerminalScrollCoordinator: NSObject, UIScrollViewDelegate {
    private let terminalView: GhosttySurfaceView
    private let scrollView: UIScrollView
    private let metricsLabel: UILabel
    private var viewportRows = 0
    private var cellHeight: CGFloat = 0
    private var boundary: TerminalScrollBoundary?
    private var state: NativeScrollState?
    private var isConfiguring = false

    init(
        terminalView: GhosttySurfaceView,
        scrollView: UIScrollView,
        metricsLabel: UILabel
    ) {
        self.terminalView = terminalView
        self.scrollView = scrollView
        self.metricsLabel = metricsLabel
        super.init()
        scrollView.delegate = self
    }

    func updateViewport(rows: Int) {
        let measuredCellHeight = terminalView.renderedCellSizeInPoints.height
        guard rows > 0, measuredCellHeight > 0, scrollView.bounds.height > 0 else { return }
        viewportRows = rows
        cellHeight = measuredCellHeight
        configureScrollRange()
    }

    func updateBoundary(_ boundary: TerminalScrollBoundary) {
        self.boundary = boundary
        viewportRows = Int(boundary.visibleRows)
        guard cellHeight > 0 else { return }
        let maximumOffsetY = CGFloat(maximumRowOffset(for: boundary)) * cellHeight
        let authoritativeOffsetY = CGFloat(
            min(boundary.viewportOffsetRows, maximumRowOffset(for: boundary))
        ) * cellHeight
        if state != nil {
            state?.updateAuthoritativeOffsetY(authoritativeOffsetY)
        }
        configureScrollRange(preferredOffsetY: min(authoritativeOffsetY, maximumOffsetY))
        reconcilePresentationWithCurrentOffset()
    }

    func updateLayout() {
        guard viewportRows > 0, cellHeight > 0 else { return }
        configureScrollRange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isConfiguring,
              var state,
              cellHeight > 0 else { return }
        let maximumOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let sample = state.sample(
            rawOffsetY: scrollView.contentOffset.y,
            maximumOffsetY: maximumOffsetY,
            cellHeight: cellHeight
        )
        self.state = state

        if sample.scrollLines != 0 {
            terminalView.applyLocalScrollbackScroll(
                lines: sample.scrollLines,
                col: 0,
                row: max(0, viewportRows / 2)
            )
        }
        terminalView.transform = CGAffineTransform(
            translationX: 0,
            y: sample.presentationTranslationY
        )
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: sample.presentationTranslationY
        )
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: terminalView.transform.ty,
            phaseOverride: String(localized: "scroll.phase.dragging", defaultValue: "DRAGGING")
        )
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard !decelerate else { return }
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: terminalView.transform.ty,
            phaseOverride: String(localized: "scroll.phase.idle", defaultValue: "IDLE")
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: terminalView.transform.ty,
            phaseOverride: String(localized: "scroll.phase.idle", defaultValue: "IDLE")
        )
    }

    private func configureScrollRange(preferredOffsetY: CGFloat? = nil) {
        guard let boundary else { return }
        let maximumOffsetY = CGFloat(maximumRowOffset(for: boundary)) * cellHeight
        isConfiguring = true
        scrollView.contentSize = CGSize(
            width: max(scrollView.bounds.width, 1),
            height: scrollView.bounds.height + maximumOffsetY
        )
        if state == nil {
            let initialOffsetY = preferredOffsetY ?? maximumOffsetY
            scrollView.contentOffset = CGPoint(x: 0, y: initialOffsetY)
            state = NativeScrollState(initialOffsetY: initialOffsetY)
        }
        isConfiguring = false
        updateMetrics(rawOffsetY: scrollView.contentOffset.y, translationY: terminalView.transform.ty)
    }

    private func maximumRowOffset(for boundary: TerminalScrollBoundary) -> UInt64 {
        boundary.totalRows > boundary.visibleRows
            ? boundary.totalRows - boundary.visibleRows
            : 0
    }

    private func reconcilePresentationWithCurrentOffset() {
        guard var state, cellHeight > 0 else { return }
        let maximumOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let sample = state.sample(
            rawOffsetY: scrollView.contentOffset.y,
            maximumOffsetY: maximumOffsetY,
            cellHeight: cellHeight
        )
        self.state = state
        terminalView.transform = CGAffineTransform(
            translationX: 0,
            y: sample.presentationTranslationY
        )
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: sample.presentationTranslationY
        )
    }

    private func updateMetrics(
        rawOffsetY: CGFloat,
        translationY: CGFloat,
        phaseOverride: String? = nil
    ) {
        let phase = phaseOverride ?? {
            if scrollView.isTracking || scrollView.isDragging {
                return String(localized: "scroll.phase.dragging", defaultValue: "DRAGGING")
            }
            if scrollView.isDecelerating {
                return String(localized: "scroll.phase.decelerating", defaultValue: "DECELERATING")
            }
            return String(localized: "scroll.phase.idle", defaultValue: "IDLE")
        }()
        let format = String(
            localized: "scroll.metrics.format",
            defaultValue: "%@  offset %.1f pt  translation %.1f pt"
        )
        metricsLabel.text = String(format: format, phase, rawOffsetY, translationY)
    }
}
