import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One list item in the scroll-pin model, in on-screen order.
enum WorkspaceListScrollPinKind: Hashable, Sendable {
    /// A workspace row. Uniform height by design while titles do not wrap:
    /// the title is a single line and the activity preview reserves its line
    /// count regardless of content.
    case workspaceRow
    /// A group header row. Uniform: single-line name over a fixed-height base.
    case groupHeader
    /// The invisible end-of-group drop slot. Uniform fixed height.
    case groupFooter
    /// A singleton whose height is not knowable up front (connection banner,
    /// offline status row, filter-empty row). It only contributes to the model
    /// once its realized height has been observed on screen.
    case variable(id: String)
}

/// The pure pinning math: given the list's item-kind sequence and the heights
/// learned from realized cells, the exact content height — or `nil` while the
/// model is incomplete, which pauses pinning (fail-open to today's behavior).
struct WorkspaceListScrollPinModel: Equatable {
    var kinds: [WorkspaceListScrollPinKind]
    /// `false` when the wrap-workspace-titles setting makes row heights
    /// content-dependent; the stabilizer then stays inert.
    var rowHeightsAreUniform: Bool

    func pinnedContentHeight(
        uniformHeights: [WorkspaceListScrollPinKind: CGFloat],
        variableHeights: [String: CGFloat]
    ) -> CGFloat? {
        guard rowHeightsAreUniform, !kinds.isEmpty else { return nil }
        var total: CGFloat = 0
        for kind in kinds {
            switch kind {
            case .variable(let id):
                guard let height = variableHeights[id] else { return nil }
                total += height
            case .workspaceRow, .groupHeader, .groupFooter:
                guard let height = uniformHeights[kind] else { return nil }
                total += height
            }
        }
        return total
    }
}

extension View {
    /// Mount the scroll-indicator stabilizer behind the workspace `List`.
    /// No-op on platforms without UIKit.
    @ViewBuilder
    func workspaceListScrollIndicatorStabilized(
        _ model: WorkspaceListScrollPinModel
    ) -> some View {
        #if canImport(UIKit)
        background(WorkspaceListScrollIndicatorStabilizer(model: model))
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
/// Pins the workspace `List`'s backing `UICollectionView.contentSize` to the
/// exact height derived from the list's own item snapshot, so the scroll
/// indicator stops stuttering.
///
/// SwiftUI's `List` sizes unrealized rows with a hardwired ~54pt estimate
/// that no public API influences (`defaultMinListRowHeight` at 16/92.5,
/// removing it entirely, and explicit fixed row frames were each measured to
/// change nothing). Workspace rows are ~92pt, so during scrolling every row
/// materialization grows `contentSize` by ~38pt and visibly jerks the scroll
/// indicator — one correction per row (long-standing Apple `List` behavior,
/// still present on iOS 26; see forum thread 716998). The workspace list is
/// uniform per row kind by design, which makes the true content height
/// exactly computable from item counts and per-kind realized heights.
/// Whenever the layout writes an estimate-based height, this view immediately
/// rewrites the exact one; the indicator then renders from a steady value.
/// In the seeded 100-row fixture this takes the indicator from 92 distinct
/// draw-time content heights per sweep to 1.
///
/// Self-calibrating and fail-open:
/// - Per-kind heights are measured from realized (visible) cells, never
///   hardcoded, so Dynamic Type sizes and row redesigns stay correct.
/// - When any visible cell disagrees with its kind's learned height (trait or
///   width change mid-flight), the kind is re-learned from the live cell on
///   the same pass.
/// - Pinning pauses while the model is incomplete (an unmeasured kind or an
///   unrealized variable row), while a reorder drag is active, when the item
///   count disagrees with the collection view, or when the caller marks row
///   heights non-uniform. Pausing means untouched system behavior.
struct WorkspaceListScrollIndicatorStabilizer: UIViewRepresentable {
    let model: WorkspaceListScrollPinModel

    func makeUIView(context: Context) -> WorkspaceListScrollIndicatorStabilizerView {
        let view = WorkspaceListScrollIndicatorStabilizerView()
        view.isUserInteractionEnabled = false
        view.model = model
        return view
    }

    func updateUIView(_ uiView: WorkspaceListScrollIndicatorStabilizerView, context: Context) {
        uiView.model = model
    }
}

final class WorkspaceListScrollIndicatorStabilizerView: UIView {
    var model = WorkspaceListScrollPinModel(kinds: [], rowHeightsAreUniform: false) {
        didSet {
            guard model != oldValue else { return }
            repinIfNeeded()
        }
    }

    private weak var listCollectionView: UICollectionView?
    private var contentSizeObservation: NSKeyValueObservation?
    private var attachLink: CADisplayLink?
    private var attachFramesLeft = 600
    /// Heights learned from realized cells, per uniform kind.
    private var uniformHeights: [WorkspaceListScrollPinKind: CGFloat] = [:]
    /// Realized heights of variable singletons, keyed by their model id.
    private var variableHeights: [String: CGFloat] = [:]
    /// Guards the KVO handler against reacting to this view's own write.
    private var isRepinning = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            stopAttaching()
            return
        }
        guard listCollectionView == nil, attachLink == nil else { return }
        // The backing UICollectionView does not exist until SwiftUI hosts the
        // List, so attachment retries per frame briefly instead of assuming
        // hierarchy timing. The link is torn down as soon as it resolves.
        let link = CADisplayLink(target: self, selector: #selector(attachTick))
        link.add(to: .main, forMode: .common)
        attachLink = link
    }

    @objc private func attachTick() {
        attachFramesLeft -= 1
        if let collectionView = nearestListCollectionView() {
            stopAttaching()
            attach(to: collectionView)
        } else if attachFramesLeft <= 0 {
            stopAttaching()
        }
    }

    private func stopAttaching() {
        attachLink?.invalidate()
        attachLink = nil
    }

    private func attach(to collectionView: UICollectionView) {
        listCollectionView = collectionView
        contentSizeObservation = collectionView.observe(
            \.contentSize, options: [.old, .new]
        ) { [weak self] _, change in
            guard change.oldValue?.height != change.newValue?.height else { return }
            // UIKit publishes contentSize changes from main-thread layout.
            MainActor.assumeIsolated {
                guard let self, !self.isRepinning else { return }
                self.repinIfNeeded()
            }
        }
        repinIfNeeded()
    }

    /// Find the List's backing collection view: walk up the ancestor chain and
    /// take the first collection view found beneath the nearest ancestor that
    /// contains one. Scoping to the nearest container keeps sheets, pushed
    /// screens, and unrelated collection views out of reach.
    private func nearestListCollectionView() -> UICollectionView? {
        var ancestor = superview
        while let current = ancestor {
            if let collectionView = Self.firstCollectionView(under: current) {
                return collectionView
            }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstCollectionView(under root: UIView) -> UICollectionView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let collectionView = view as? UICollectionView {
                return collectionView
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func repinIfNeeded() {
        guard let collectionView = listCollectionView else { return }
        guard model.rowHeightsAreUniform else { return }
        // A reorder drag owns the layout; leave it alone until it settles.
        guard !collectionView.hasActiveDrag else { return }
        guard learnHeights(from: collectionView) else { return }
        guard let pinned = model.pinnedContentHeight(
            uniformHeights: uniformHeights,
            variableHeights: variableHeights
        ) else { return }
        guard abs(collectionView.contentSize.height - pinned) > 0.5 else { return }
        isRepinning = true
        collectionView.contentSize.height = pinned
        isRepinning = false
    }

    /// Learn/refresh per-kind heights from the currently visible (hence
    /// realized) cells. Returns `false` when the collection view's item count
    /// does not match the model — the snapshot and the layout are mid-update,
    /// so this pass must not pin.
    private func learnHeights(from collectionView: UICollectionView) -> Bool {
        var sectionStarts: [Int] = []
        var total = 0
        for section in 0..<collectionView.numberOfSections {
            sectionStarts.append(total)
            total += collectionView.numberOfItems(inSection: section)
        }
        guard total == model.kinds.count else { return false }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard indexPath.section < sectionStarts.count else { return false }
            let globalIndex = sectionStarts[indexPath.section] + indexPath.item
            guard globalIndex < model.kinds.count else { return false }
            guard
                let height = collectionView.layoutAttributesForItem(at: indexPath)?.frame.height
            else { continue }
            switch model.kinds[globalIndex] {
            case .variable(let id):
                variableHeights[id] = height
            case let kind:
                uniformHeights[kind] = height
            }
        }
        return true
    }
}
#endif
