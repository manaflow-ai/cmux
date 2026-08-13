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
    private var lastRequestedViewportRow: UInt64?
    private var hasObservedDeceleration = false
    private var hasRequestedLocalViewport = false
    private var currentPresentationTranslationY: CGFloat = 0
    private var presentedViewportRow: UInt64?
    private let shouldApplyHalfRowOffsetForTesting: Bool

    init(
        terminalView: GhosttySurfaceView,
        scrollView: UIScrollView,
        metricsLabel: UILabel,
        shouldApplyHalfRowOffsetForTesting: Bool = false
    ) {
        self.terminalView = terminalView
        self.scrollView = scrollView
        self.metricsLabel = metricsLabel
        self.shouldApplyHalfRowOffsetForTesting = shouldApplyHalfRowOffsetForTesting
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
        if !hasRequestedLocalViewport {
            presentedViewportRow = boundary.viewportOffsetRows
            state?.updateAuthoritativeOffsetY(authoritativeOffsetY)
        }
        configureScrollRange(preferredOffsetY: min(authoritativeOffsetY, maximumOffsetY))
        reconcilePresentationWithCurrentOffset()
        applyHalfRowOffsetForTestingIfNeeded()
    }

    func updatePresentedViewport(row: UInt64) {
        presentedViewportRow = row
        state?.updateAuthoritativeOffsetY(CGFloat(row) * cellHeight)
        reconcilePresentationWithCurrentOffset()
    }

    func updateLayout() {
        guard viewportRows > 0, cellHeight > 0 else { return }
        configureScrollRange()
        applyHalfRowOffsetForTestingIfNeeded()
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

        if sample.targetViewportRow != lastRequestedViewportRow {
            lastRequestedViewportRow = sample.targetViewportRow
            hasRequestedLocalViewport = true
            terminalView.applyLocalScrollbackViewport(row: sample.targetViewportRow)
        }
        currentPresentationTranslationY = terminalView.applyLocalScrollbackPresentation(
            translationY: sample.presentationTranslationY
        )
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: currentPresentationTranslationY
        )
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        hasObservedDeceleration = false
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: currentPresentationTranslationY,
            phaseOverride: String(localized: "scroll.phase.dragging", defaultValue: "DRAGGING")
        )
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        hasObservedDeceleration = decelerate
        guard !decelerate else { return }
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: currentPresentationTranslationY,
            phaseOverride: String(localized: "scroll.phase.idle", defaultValue: "IDLE")
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: currentPresentationTranslationY,
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
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: currentPresentationTranslationY
        )
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
        currentPresentationTranslationY = terminalView.applyLocalScrollbackPresentation(
            translationY: sample.presentationTranslationY
        )
        updateMetrics(
            rawOffsetY: scrollView.contentOffset.y,
            translationY: currentPresentationTranslationY
        )
    }

    private func applyHalfRowOffsetForTestingIfNeeded() {
        let maximumOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        guard shouldApplyHalfRowOffsetForTesting,
              state != nil,
              cellHeight > 0,
              maximumOffsetY > cellHeight else { return }
        let targetOffsetY = maximumOffsetY - cellHeight / 2
        guard abs(scrollView.contentOffset.y - targetOffsetY) > 0.01 else {
            scrollViewDidScroll(scrollView)
            return
        }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
            animated: false
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
            defaultValue: "%@  offset %.1f / %.1f pt  translation %.1f pt"
        )
        let maximumOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        metricsLabel.text = String(
            format: format,
            phase,
            rawOffsetY,
            maximumOffsetY,
            translationY
        )
        let deceleration = hasObservedDeceleration
            ? String(
                localized: "scroll.deceleration.observed",
                defaultValue: "Deceleration observed"
            )
            : String(
                localized: "scroll.deceleration.not-observed",
                defaultValue: "Deceleration not observed"
            )
        let targetRow = cellHeight > 0
            ? UInt64(max(0, (min(max(rawOffsetY, 0), maximumOffsetY) / cellHeight).rounded()))
            : 0
        let renderedRow = presentedViewportRow ?? boundary?.viewportOffsetRows ?? 0
        let auditFormat = String(
            localized: "scroll.audit.format",
            defaultValue: "%@; %@; %@; target row %llu; rendered row %llu"
        )
        let chromeStatus = terminalView.transform == .identity
            ? String(localized: "scroll.chrome.stable", defaultValue: "Fixed chrome stable")
            : String(localized: "scroll.chrome.moved", defaultValue: "Fixed chrome moved")
        let rendererStatus = abs(translationY) >= 0.5 / max(metricsLabel.traitCollection.displayScale, 1)
            ? String(
                localized: "scroll.renderer.fractional-active",
                defaultValue: "Fractional renderer active"
            )
            : String(
                localized: "scroll.renderer.fractional-inactive",
                defaultValue: "Fractional renderer inactive"
            )
        metricsLabel.accessibilityValue = String(
            format: auditFormat,
            deceleration,
            chromeStatus,
            rendererStatus,
            targetRow,
            renderedRow
        )
    }
}
