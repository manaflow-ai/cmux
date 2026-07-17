#if canImport(UIKit) && DEBUG
import SwiftUI
import UIKit
import os

/// DEBUG-only scroll-estimation instrumentation for the workspace-list preview
/// fixture (`CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1`).
///
/// The scroll indicator of a self-sizing `List` stutters exactly when the
/// backing list scroll view's `contentSize` is corrected mid-scroll (an
/// estimated row height was replaced by the realized height). This probe
/// makes that churn measurable: it locates the list's table/collection view,
/// observes `contentSize` height corrections, optionally drives a
/// top-to-bottom sweep (`CMUX_UITEST_SCROLL_SWEEP=1`), and writes
/// `Documents/scroll-metrics.json` so the host can pull quantitative
/// before/after evidence from the app container.
struct WorkspaceListScrollMetricsProbe: UIViewRepresentable {
    let runsSweep: Bool

    func makeUIView(context: Context) -> WorkspaceListScrollMetricsProbeView {
        let view = WorkspaceListScrollMetricsProbeView()
        view.runsSweep = runsSweep
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: WorkspaceListScrollMetricsProbeView, context: Context) {}
}

/// The backing `UIView` that hosts the display link, KVO observation, and
/// report writing for ``WorkspaceListScrollMetricsProbe``.
final class WorkspaceListScrollMetricsProbeView: UIView {
    var runsSweep = false

    private enum Phase {
        /// Waiting for the list's UIKit scroll view to exist in the window.
        case searching(framesLeft: Int)
        /// Attached; letting initial layout settle before baselining.
        case settling(framesLeft: Int)
        /// Stepping the content offset from top to bottom.
        case sweeping
        /// Sweep complete (or observation-only mode); KVO stays live.
        case finished
    }

    private struct Correction: Encodable {
        let offsetY: Double
        let oldHeight: Double
        let newHeight: Double
    }

    private struct Report: Encodable {
        let finished: Bool
        let initialContentHeight: Double
        let finalContentHeight: Double
        let correctionCount: Int
        let totalAbsCorrection: Double
        /// EXPERIMENT E: distinct contentSize heights observed at frame-draw
        /// time during the sweep. This is what the scroll indicator actually
        /// renders from: 1 distinct value = rock-steady indicator.
        let distinctDrawHeights: [Double]
        /// Realized item heights (rounded to 0.5pt) with occurrence counts,
        /// captured after the sweep so every row has a measured height. Shows
        /// what the per-row estimate should have been.
        let realizedHeightCounts: [String: Int]
        let corrections: [Correction]
    }

    private static let logger = Logger(subsystem: "dev.cmux.ios", category: "scroll-metrics")
    /// ~4200 pt/s at 60 Hz: a realistic fast-flick velocity, fast enough to
    /// outrun cell materialization the way a user's flick does.
    private static let sweepStepPoints: CGFloat = 70

    private weak var listScrollView: UIScrollView?
    private var contentSizeObservation: NSKeyValueObservation?
    private var displayLink: CADisplayLink?
    private var phase: Phase = .searching(framesLeft: 600)
    private var corrections: [Correction] = []
    private var initialContentHeight: Double = 0
    private var sweepFinished = false
    /// `contentSize.height` sampled once per sweep frame — the value the
    /// scroll indicator actually renders from at draw time.
    private var sampledDrawHeights: [Double] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The display link retains its target, so it must be torn down when
        // the probe leaves the window (deinit is nonisolated under Swift 6 and
        // cannot do it).
        guard window != nil else {
            stopTicking()
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        switch phase {
        case .searching(let framesLeft):
            if let scrollView = Self.findListScrollView(in: window) {
                attach(to: scrollView)
                phase = .settling(framesLeft: 90)
            } else if framesLeft <= 0 {
                Self.logger.error("scroll-metrics: no UITableView/UICollectionView found; giving up")
                stopTicking()
            } else {
                phase = .searching(framesLeft: framesLeft - 1)
            }
        case .settling(let framesLeft):
            if framesLeft > 0 {
                phase = .settling(framesLeft: framesLeft - 1)
                return
            }
            baselineAfterSettle()
        case .sweeping:
            sampledDrawHeights.append(Double(listScrollView?.contentSize.height ?? 0))
            stepSweep()
        case .finished:
            // KVO stays live so manual scrolling keeps appending corrections;
            // the display link is no longer needed.
            stopTicking()
        }
    }

    /// Reset the correction log after launch layout settles, so the report
    /// counts only scroll-driven estimate corrections, then start the sweep
    /// (or hand over to manual scrolling in observation-only mode).
    private func baselineAfterSettle() {
        guard let scrollView = listScrollView else {
            stopTicking()
            return
        }
        initialContentHeight = scrollView.contentSize.height
        corrections = []
        if runsSweep {
            var top = scrollView.contentOffset
            top.y = -scrollView.adjustedContentInset.top
            scrollView.contentOffset = top
            phase = .sweeping
        } else {
            phase = .finished
            writeReport()
        }
    }

    private func stepSweep() {
        guard let scrollView = listScrollView else {
            stopTicking()
            return
        }
        let maxOffsetY = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height
        )
        var next = scrollView.contentOffset
        next.y = min(next.y + Self.sweepStepPoints, maxOffsetY)
        scrollView.contentOffset = next
        if next.y >= maxOffsetY {
            sweepFinished = true
            phase = .finished
            writeReport()
            Self.logger.notice(
                "scroll-metrics: sweep done corrections=\(self.corrections.count) totalAbsCorrection=\(self.totalAbsCorrection, format: .fixed(precision: 1)) initial=\(self.initialContentHeight, format: .fixed(precision: 1)) final=\(Double(self.listScrollView?.contentSize.height ?? 0), format: .fixed(precision: 1))"
            )
        }
    }

    private func attach(to scrollView: UIScrollView) {
        listScrollView = scrollView
        initialContentHeight = scrollView.contentSize.height
        contentSizeObservation = scrollView.observe(
            \.contentSize, options: [.old, .new]
        ) { [weak self] _, change in
            guard
                let oldHeight = change.oldValue?.height,
                let newHeight = change.newValue?.height,
                abs(newHeight - oldHeight) > 0.5
            else { return }
            // UIKit publishes contentSize changes from main-thread layout.
            MainActor.assumeIsolated {
                self?.recordCorrection(oldHeight: oldHeight, newHeight: newHeight)
            }
        }
    }

    private func recordCorrection(oldHeight: CGFloat, newHeight: CGFloat) {
        guard let scrollView = listScrollView else { return }
        if case .searching = phase { return }
        if case .settling = phase { return }
        corrections.append(
            Correction(
                offsetY: scrollView.contentOffset.y,
                oldHeight: oldHeight,
                newHeight: newHeight
            )
        )
        writeReport()
    }

    private var totalAbsCorrection: Double {
        corrections.reduce(0) { $0 + abs($1.newHeight - $1.oldHeight) }
    }

    private func writeReport() {
        guard
            let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first
        else { return }
        let finished = sweepFinished || !runsSweep
        let report = Report(
            finished: finished,
            initialContentHeight: initialContentHeight,
            finalContentHeight: Double(listScrollView?.contentSize.height ?? 0),
            correctionCount: corrections.count,
            totalAbsCorrection: totalAbsCorrection,
            distinctDrawHeights: Array(Set(sampledDrawHeights.map { ($0 * 2).rounded() / 2 })).sorted(),
            // Queried only once the sweep is done: mid-sweep reports are
            // written from a KVO callback inside a layout pass, where an extra
            // whole-content layout query is both wasted work and reentrant.
            realizedHeightCounts: finished ? realizedHeightCounts() : [:],
            corrections: corrections
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(
            to: documents.appendingPathComponent("scroll-metrics.json"),
            options: [.atomic]
        )
    }

    /// Item heights the layout has realized so far, keyed by height rounded to
    /// 0.5pt. After a full sweep every item is realized, so this is the true
    /// height distribution the estimates should match.
    private func realizedHeightCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        if let tableView = listScrollView as? UITableView {
            for section in 0..<tableView.numberOfSections {
                for row in 0..<tableView.numberOfRows(inSection: section) {
                    let height = tableView.rectForRow(at: IndexPath(row: row, section: section)).height
                    let rounded = (height * 2).rounded() / 2
                    counts[String(format: "%.1f", rounded), default: 0] += 1
                }
            }
        } else if let collectionView = listScrollView as? UICollectionView {
            let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(
                in: CGRect(origin: .zero, size: collectionView.contentSize)
            ) ?? []
            for attribute in attributes where attribute.representedElementCategory == .cell {
                let rounded = (attribute.frame.height * 2).rounded() / 2
                counts[String(format: "%.1f", rounded), default: 0] += 1
            }
        }
        return counts
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private static func findListScrollView(in window: UIWindow?) -> UIScrollView? {
        guard let window else { return nil }
        var queue: [UIView] = [window]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let tableView = view as? UITableView {
                return tableView
            }
            if let collectionView = view as? UICollectionView {
                return collectionView
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
#endif
