#if canImport(UIKit) && DEBUG
import CmuxConversationGeometry
import UIKit

/// DEBUG lab, for A/B runs on a device; not shipped.
///
/// `CMUX_UITEST_CONVERSATION_DYNAMICS=1` turns on ChatKit's transcript
/// dynamics (`ConversationTranscriptDynamics`): rows hold their place on
/// screen when the content offset moves and close the gap each displayed
/// frame, rows far from the finger more slowly, so the transcript trails the
/// finger by a few points the way Messages' does.
///
/// `CMUX_UITEST_CONVERSATION_SCROLL_RATE=120` asks for 120 Hz UI updates
/// while the transcript is dragged or decelerating, without dynamics, to see
/// whether UIKit's own frame-rate reduction at the end of a fling is what
/// reads as uneven.
///
/// Both run in the update cycle after the display links (where ChatKit's
/// `transcriptDynamics` update-sequence item runs), so they see the offset
/// the frame will show, and stay passive while nothing moves.
@MainActor
final class ConversationTranscriptDynamicsDriver {
    static let dynamicsKey = "CMUX_UITEST_CONVERSATION_DYNAMICS"
    static let rateKey = "CMUX_UITEST_CONVERSATION_SCROLL_RATE"

    private struct Row {
        /// Where the row's top is drawn, in the transcript's visible bounds.
        var shown: CGFloat
        var easing: Double
        var targetEasing: Double
    }

    private weak var controller: ConversationViewController?
    let dynamics: Bool
    private let holdsRate: Bool
    private var link: AnyObject?
    private var rows: [String: Row] = [:]
    private var lastOffset: CGFloat?
    private var lastModelTime: Double?
    /// The drag's first touch, in content coordinates.
    private var anchorY: CGFloat?
    /// A fling's resting offset, set at release.
    private var flingTarget: CGFloat?
    /// Clamp neighbors from the bottom up (content moving up) or top down.
    private var clampsUpward = true

    init(controller: ConversationViewController, dynamics: Bool, holdsRate: Bool) {
        self.controller = controller
        self.dynamics = dynamics
        self.holdsRate = holdsRate
    }

    /// The driver the environment asks for, or nil.
    static func fromEnvironment(controller: ConversationViewController) -> ConversationTranscriptDynamicsDriver? {
        let environment = ProcessInfo.processInfo.environment
        let dynamics = environment[dynamicsKey] == "1" && !UIAccessibility.isReduceMotionEnabled
        let holdsRate = environment[rateKey] == "120"
        guard dynamics || holdsRate else { return nil }
        return ConversationTranscriptDynamicsDriver(controller: controller, dynamics: dynamics, holdsRate: holdsRate)
    }

    func start() {
        guard link == nil, let controller, #available(iOS 18.0, *) else { return }
        let link = UIUpdateLink(view: controller.collectionView)
        link.addAction(to: .afterCADisplayLinkDispatch) { [weak self] _, info in
            self?.update(modelTime: info.modelTime)
        }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.isEnabled = true
        self.link = link
        if dynamics {
            controller.collectionView.cellOffset = { [weak self] cell in self?.offset(for: cell) ?? 0 }
        }
    }

    /// The drag begins: rows trail by their distance from this touch.
    func dragBegan(atContentY y: CGFloat) {
        anchorY = y
        flingTarget = nil
        for (id, row) in rows {
            rows[id]?.targetEasing = targetEasing(rowID: id) ?? row.targetEasing
        }
    }

    /// The finger lifts toward `offsetY`: rows past the first screen trail further.
    func dragEnded(targetOffsetY offsetY: CGFloat) {
        flingTarget = offsetY
        for (id, row) in rows {
            rows[id]?.targetEasing = targetEasing(rowID: id) ?? row.targetEasing
        }
    }

    /// A change that moves rows itself (an animated insertion, a scroll to
    /// the newest message) starts from the layout, with no trailing rows.
    func reset() {
        guard dynamics else { return }
        rows = [:]
        lastOffset = controller?.collectionView.contentOffset.y
        apply()
    }

    private func update(modelTime: Double) {
        guard let controller else { return }
        let scrollView = controller.collectionView
        let offset = scrollView.contentOffset.y
        let step = lastOffset.map { offset - $0 } ?? 0
        lastOffset = offset
        // The frame's length, as ChatKit takes it from its display link; a
        // first update after a pause counts as one 120 Hz frame.
        let elapsed = lastModelTime.map { modelTime - $0 } ?? 0
        lastModelTime = modelTime
        let duration = elapsed > 0 && elapsed < 0.05 ? elapsed : 1.0 / 120
        let moving = scrollView.isTracking || scrollView.isDecelerating
        var unsettled = false
        if dynamics {
            unsettled = advance(step: step, duration: duration, offset: offset)
            apply()
        }
        if #available(iOS 18.0, *), let link = link as? UIUpdateLink {
            let continuous = (holdsRate && moving) || (dynamics && (moving || unsettled))
            if link.requiresContinuousUpdates != continuous { link.requiresContinuousUpdates = continuous }
        }
    }

    /// One displayed frame of the dynamics; returns whether any row is still
    /// away from its place.
    private func advance(step: CGFloat, duration: Double, offset: CGFloat) -> Bool {
        guard let controller else { return false }
        let scrollView = controller.collectionView
        let bounds = scrollView.bounds
        let scale = max(1, scrollView.traitCollection.displayScale)
        let ids = controller.transcriptItemIDs()
        // ChatKit moves every row of its (windowed) transcript each frame; two
        // screens either side keep a row's trail continuous before it shows.
        let window = controller.layout.itemRange(in: bounds.insetBy(dx: 0, dy: -2 * bounds.height))
        if step > 0 { clampsUpward = true } else if step < 0 { clampsUpward = false }
        let adopt = abs(step) > ConversationTranscriptDynamics.easingAdoptionStep
        var next: [String: Row] = [:]
        var placed: [(id: String, target: CGFloat, height: CGFloat, gapAbove: CGFloat)] = []
        var previousMaxY: CGFloat?
        let indices = window.filter { $0 < ids.count }
        // A row coming into the window starts with its neighbor's trail.
        var lastTrail: CGFloat?
        var entering: [Int] = []
        for (position, index) in indices.enumerated() {
            guard let frame = controller.layout.frame(at: index) else { continue }
            let id = ids[index]
            let target = frame.minY - offset
            var row: Row
            if let known = rows[id] {
                row = known
                if lastTrail == nil {
                    // Rows above that entered before any known one take this trail.
                    for k in entering { next[ids[indices[k]]]?.shown += known.shown - target }
                }
                lastTrail = known.shown - target
            } else {
                row = Row(shown: target + (lastTrail ?? 0), easing: 0, targetEasing: targetEasing(rowID: id) ?? 0)
                if lastTrail == nil { entering.append(position) }
            }
            if adopt { row.easing = row.targetEasing }
            next[id] = row
            placed.append((id, target, frame.height, previousMaxY.map { frame.minY - $0 } ?? .greatestFiniteMagnitude))
            previousMaxY = frame.maxY
        }
        for item in placed {
            guard var row = next[item.id] else { continue }
            row.shown = ConversationTranscriptDynamics.advance(current: row.shown, target: item.target, easing: row.easing, duration: duration, scale: scale)
            next[item.id] = row
        }
        // Neighbors never close in on each other past a run's spacing.
        let minimumGap = ConversationTheme.groupedSpacing
        if clampsUpward {
            for i in stride(from: placed.count - 2, through: 0, by: -1) {
                let lower = placed[i + 1], upper = placed[i]
                guard let below = next[lower.id]?.shown, var row = next[upper.id] else { continue }
                let limit = below - min(lower.gapAbove, minimumGap) - upper.height
                if row.shown > limit { row.shown = limit; next[upper.id] = row }
            }
        } else {
            for i in 1..<max(1, placed.count) {
                let upper = placed[i - 1], lower = placed[i]
                guard let above = next[upper.id]?.shown, var row = next[lower.id] else { continue }
                let limit = above + upper.height + min(lower.gapAbove, minimumGap)
                if row.shown < limit { row.shown = limit; next[lower.id] = row }
            }
        }
        var unsettled = false
        for item in placed {
            guard var row = next[item.id] else { continue }
            if abs(step) > ConversationTranscriptDynamics.pixelRoundingStep {
                row.shown = (row.shown * scale).rounded() / scale
                next[item.id] = row
            }
            if row.shown != item.target { unsettled = true }
        }
        rows = next
        return unsettled
    }

    /// How far a cell's row is drawn from its place in the layout.
    private func offset(for cell: UICollectionViewCell) -> CGFloat {
        guard let controller, let indexPath = controller.collectionView.indexPath(for: cell),
              let frame = controller.layout.frame(at: indexPath.item) else { return 0 }
        let ids = controller.transcriptItemIDs()
        guard indexPath.item < ids.count, let row = rows[ids[indexPath.item]] else { return 0 }
        return row.shown - (frame.minY - controller.collectionView.contentOffset.y)
    }

    private func apply() {
        guard let controller else { return }
        let scrollView = controller.collectionView
        for cell in scrollView.visibleCells {
            TranscriptCollectionView.place(cell, offset: offset(for: cell))
        }
    }

    private func targetEasing(rowID: String) -> Double? {
        guard let controller, let anchorY, let index = controller.transcriptIndex(ofItemID: rowID),
              let frame = controller.layout.frame(at: index) else { return nil }
        let base = ConversationTranscriptDynamics.baseEasing(side(at: index))
        let viewport = controller.collectionView.bounds.height
        let distance = abs(frame.midY - anchorY)
        if let flingTarget,
           let far = ConversationTranscriptDynamics.flingEasing(
               base: base, centerDistance: distance, height: frame.height, viewport: viewport,
               range: ConversationTranscriptDynamics.flingRange(anchorY: anchorY, targetOffsetY: flingTarget, viewport: viewport)
           ) {
            return far
        }
        return ConversationTranscriptDynamics.anchorEasing(base: base, centerDistance: distance, height: frame.height, viewport: viewport)
    }

    private func side(at index: Int) -> ConversationTranscriptDynamics.Side {
        guard let controller else { return .centered }
        switch controller.rows[index] {
        case let .message(model): return model.isOutgoing ? .outgoing : .incoming
        case .typing: return .incoming
        default: return .centered
        }
    }
}

#endif
