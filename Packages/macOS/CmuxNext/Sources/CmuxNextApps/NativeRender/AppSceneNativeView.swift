import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// Renders one mounted contribution's scene in AppKit: the custom sidebar section a JS app (the
/// customize app's `cmux.section/1`) describes as a tree of kit nodes, drawn with the sidebar's own
/// row tokens and theme so it reads as a built-in section (no SwiftUI, no web view).
///
/// The script's scene arrives as op batches (`apps-scene`) that the model applies; this view keeps one
/// ``AppSceneNodeNSView`` per node id and, on each change, reconfigures the views whose node changed,
/// makes views for new nodes and drops the views of removed ones. A change is noticed by Observation
/// (no polling) while the view is in a window, and any layout pass draws a pending one; ``onContentSizeChange`` tells the host when the
/// height may have changed. Loading draws nothing; a failed or disconnected mount draws one quiet row
/// with the reason. Every node type of the kit has an AppKit view here, so no scene falls back to
/// SwiftUI.
final class AppSceneNativeView: NSView {
    let model: AppSceneModel
    /// The app bundle's folder: `Image` nodes read their `src` from it.
    let bundleDirectory: URL?
    /// Runs after a redraw that may have changed ``preferredHeight(width:)``.
    var onContentSizeChange: (() -> Void)?
    private var views: [String: AppSceneNodeNSView] = [:]
    private var rootView: AppSceneNodeNSView?
    private let failure = ChromeLabel(wrappingLabelWithString: "")
    private var drawnRevision = -1
    private var drawnStatus: AppSceneModel.Status?

    init(model: AppSceneModel, bundleDirectory: URL? = nil) {
        self.model = model
        self.bundleDirectory = bundleDirectory
        super.init(frame: .zero)
        wantsLayer = true
        failure.font = Typography.caption
        failure.maximumNumberOfLines = 3
        failure.isHidden = true
        addSubview(failure)
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    /// What a redraw depends on: the applied batch count and the status.
    private struct Pass: Equatable, Sendable {
        let revision: Int
        let status: AppSceneModel.Status
    }

    /// The task that redraws on each scene change while the view is in a window.
    private var feed: Task<Void, Never>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        feed?.cancel()
        feed = nil
        guard window != nil else { return }
        // task-owner: this view (cancelled when it leaves its window); event-driven (Observation), one
        // wake per change burst, after the main-actor transaction that applied the ops.
        feed = Task { [weak self, model] in
            for await _ in ObservationStream({ () -> Pass in
                _ = model.scene // tracked: every applied batch replaces the scene's nodes
                return Pass(revision: model.revision, status: model.status)
            }) {
                self?.redrawIfNeeded()
            }
        }
    }

    /// Redraws when the model changed since the last draw; reports a size change.
    func redrawIfNeeded() {
        guard model.revision != drawnRevision || model.status != drawnStatus else { return }
        drawnRevision = model.revision
        drawnStatus = model.status
        let before = rootView.map { $0.height(width: bounds.width) }
        reconcile()
        needsLayout = true
        invalidateIntrinsicContentSize()
        if before != rootView.map({ $0.height(width: bounds.width) }) || !failure.isHidden { onContentSizeChange?() }
    }

    private func reconcile() {
        switch model.status {
        case .failed(let reason), .disconnected(let reason):
            failure.stringValue = reason
            failure.isHidden = false
            rootView?.removeFromSuperview()
            rootView = nil
            views.removeAll()
            return
        case .loading, .ready:
            failure.isHidden = true
        }
        var live = Set<String>()
        let next = model.scene.root.flatMap { view(for: $0, live: &live) }
        views = views.filter { live.contains($0.key) }
        if next !== rootView {
            rootView?.removeFromSuperview()
            if let next { addSubview(next) }
            rootView = next
        }
    }

    /// The view of node `id`, reused when the node keeps its type, configured with its current value,
    /// and given its children's views.
    private func view(for id: String, live: inout Set<String>) -> AppSceneNodeNSView? {
        guard let node = model.scene[id], live.insert(id).inserted else { return nil }
        let view: AppSceneNodeNSView
        if let existing = views[id], existing.node.type == node.type {
            view = existing
            if existing.node != node { existing.configure(node) }
        } else {
            view = Self.make(id: id, node: node)
            view.model = model
            view.bundleDirectory = bundleDirectory
            view.configure(node)
            views[id] = view
        }
        if Self.isContainer(node.type) {
            view.setChildren(model.scene.flattenedChildren(of: id).compactMap { self.view(for: $0, live: &live) })
        }
        return view
    }

    private static func isContainer(_ type: AppSceneNodeType) -> Bool {
        switch type {
        case .vStack, .lazyVStack, .group, .forEach, .reorderable, .hStack, .zStack, .panel, .button: true
        default: false
        }
    }

    private static func make(id: String, node: AppSceneNode) -> AppSceneNodeNSView {
        switch node.type {
        case .row: AppSceneRowNSView(id: id, node: node)
        case .text: AppSceneTextNSView(id: id, node: node)
        case .icon: AppSceneIconNSView(id: id, node: node)
        case .image: AppSceneImageNSView(id: id, node: node)
        case .badge: AppSceneBadgeNSView(id: id, node: node)
        case .emptyState: AppSceneEmptyStateNSView(id: id, node: node)
        case .divider: AppSceneDividerNSView(id: id, node: node)
        case .spacer: AppSceneSpacerNSView(id: id, node: node)
        case .button: AppSceneButtonNSView(id: id, node: node)
        case .menu: AppSceneMenuNSView(id: id, node: node)
        case .panel: AppScenePanelNSView(id: id, node: node)
        case .toggle: AppSceneToggleNSView(id: id, node: node)
        case .slider: AppSceneSliderNSView(id: id, node: node)
        case .textField: AppSceneTextFieldNSView(id: id, node: node)
        case .progressView: AppSceneProgressNSView(id: id, node: node)
        case .circle, .capsule, .rectangle, .roundedRectangle: AppSceneShapeNSView(id: id, node: node)
        case .zStack: AppSceneZStackNSView(id: id, node: node)
        case .vStack, .lazyVStack, .group, .forEach, .reorderable, .hStack: AppSceneStackNSView(id: id, node: node)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    /// The scene's height laid out `width` points wide.
    func preferredHeight(width: CGFloat) -> CGFloat {
        redrawIfNeeded()
        if !failure.isHidden { return ceil(failure.size(forWidth: max(0, width - 2 * failureInset)).height) + 2 * Metrics.space2 }
        return ceil(rootView?.height(width: width) ?? 0)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight(width: bounds.width))
    }

    private var failureInset: CGFloat { Metrics.space4 }

    override func layout() {
        redrawIfNeeded()
        super.layout()
        if !failure.isHidden {
            let height = ceil(failure.size(forWidth: max(0, bounds.width - 2 * failureInset)).height)
            failure.frame = CGRect(x: failureInset, y: Metrics.space2, width: max(0, bounds.width - 2 * failureInset), height: height)
        }
        guard let rootView else { return }
        let width = min(rootView.naturalWidth ?? bounds.width, bounds.width)
        rootView.frame = CGRect(x: 0, y: 0, width: width, height: rootView.height(width: width))
    }

    override func updateLayer() {
        performWithTheme { failure.textColor = Palette.textSecondary }
    }

    nonisolated override var wantsUpdateLayer: Bool { true }
}
