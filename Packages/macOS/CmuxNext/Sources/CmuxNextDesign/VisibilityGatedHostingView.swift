public import AppKit
public import CmuxNextWakeups

/// A tab content view that hosts SwiftUI and stops its graph work while the tab's node is hidden
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section B, task 214).
///
/// A parked page stays in the window (hidden), and SwiftUI keeps evaluating the bodies its model
/// changes invalidate. While the node it follows is hidden, this view takes its hosting view out of
/// the hierarchy and puts it back in the show turn, with the keyboard focus it held. The hide turn
/// draws nothing and keeps no picture: the parked page is hidden, and a snapshot draws the page when
/// it is asked for (``withHosting(_:)``, `NSView.cachedDisplayImage()`). Chromium does the same for a
/// hidden WebContents: `RenderWidgetHostImpl::WasHidden` stops the renderer's frames, and a capture
/// asks the renderer for a frame (content/browser/renderer_host/render_widget_host_impl.cc).
///
/// The hosting view leaving the window runs its SwiftUI `onDisappear`, and coming back runs `onAppear`
/// and `.task` again: a gated page seeds its state where it is made (`State(initialValue:)`, its
/// model), never in an appear handler.
///
/// An occluded node keeps its hosting view (Chrome's `OCCLUDED` keeps the renderer alive), and so does a
/// hidden node that a capture vote holds (``VisibilityNode/isCaptured``): a screenshot reads the live page.
///
/// Until ``follow(_:observations:)`` this is a plain container. A page that must keep its hosting view
/// while hidden says why with ``Policy/optOut(reason:)``; it still counts its bodies.
///
/// ```swift
/// let gate = VisibilityGatedHostingView(owner: "Tasks", hosting: NSHostingView(rootView: TasksView(model: model)))
/// gate.follow(cache.node(for: key), observations: services.observations)
/// ```
@MainActor public final class VisibilityGatedHostingView: NSView, VisibilityGatedContent {
    /// Whether a page's hosting view leaves the hierarchy while its node is hidden.
    public enum Policy: Sendable, Equatable {
        /// It leaves while hidden and comes back in the show turn.
        case gated
        /// It stays, for `reason` (an `onAppear` side effect, a view that must keep running while hidden).
        case optOut(reason: String)
    }

    /// The kind of page, for `debug.observations` (`Hosting.<owner>`).
    public let owner: String
    /// This page's rule.
    public let policy: Policy
    /// The SwiftUI hosting view, in this view or (while gated) held out of it.
    public let hosting: NSView
    /// Whether the hosting view is out of the hierarchy now.
    public private(set) var isGated = false
    /// The bodies the root evaluated, and the part of them while the node was hidden (tests, Debug).
    public var bodyEvaluations: (total: Int, hidden: Int) { (counter.total, counter.hidden) }

    public var visibilityGate: VisibilityGatedHostingView? { self }

    /// The view that takes the keyboard when the page's tab is focused: the hosting view (this
    /// container takes none).
    public var focusTarget: NSView { hosting }

    private let counter: HostingBodyCounter
    private var edges: [NSLayoutConstraint] = []
    private var node: VisibilityNode?
    private var flips: VisibilitySubscription?
    private var exemptions: VisibilitySubscription?
    private weak var ledger: ObservationLedger?
    /// The view inside the hosting view that had the keyboard when it left.
    private weak var focused: NSView?

    /// Gates `hosting` (the page's `NSHostingView`, made by the page) with a counter of its own; its bodies
    /// count only where the page records them (``init(owner:policy:counter:hosting:)``).
    public convenience init(owner: String, policy: Policy = .gated, hosting: NSView) {
        self.init(owner: owner, policy: policy, counter: HostingBodyCounter(), hosting: hosting)
    }

    /// Gates `hosting`, whose SwiftUI records each body evaluation into `counter` (``bodyEvaluations``,
    /// `debug.observations`): the page passes the same counter to its root view.
    public init(owner: String, policy: Policy = .gated, counter: HostingBodyCounter, hosting: NSView) {
        self.owner = owner
        self.policy = policy
        self.counter = counter
        self.hosting = hosting
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        edges = [
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(edges)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Following a node

    /// Follows `node` (the tab's, `TabContentCache.node(for:)`): the hosting view leaves while it is hidden
    /// and comes back when it shows. Counts go to `observations` under `Hosting.<owner>`. Following the same
    /// node again does nothing; another node replaces it (a tab moved to another pane keeps its node).
    public func follow(_ node: VisibilityNode, observations: ObservationLedger?) {
        if observations !== ledger {
            ledger = observations
            counter.owner = observations?.owner("Hosting.\(owner)")
        }
        guard node !== self.node else { return }
        self.node = node
        counter.node = node
        flips = node.subscribe(owner: "Hosting.\(owner)") { [weak self] _ in self?.apply() }
        exemptions = node.subscribeExemption(owner: "Hosting.\(owner)") { [weak self] in self?.apply() }
        apply()
    }

    /// Stops following: the hosting view comes back and stays.
    public func unfollow() {
        flips = nil
        exemptions = nil
        node = nil
        counter.node = nil
        restore()
    }

    private var keepsHosting: Bool {
        guard case .gated = policy, let node else { return true }
        return node.effective != .hidden || node.isCaptured
    }

    private func apply() {
        if keepsHosting { restore() } else { gate() }
    }

    // MARK: Out and back

    private func gate() {
        guard !isGated else { return }
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: hosting) { focused = responder }
        isGated = true
        hosting.removeFromSuperview()
    }

    private func restore() {
        guard isGated else { return }
        isGated = false
        attachHosting()
        // The keyboard left with the hosting view only when nothing took it since (the window holds it).
        if let focused, let window, window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(focused)
        }
        focused = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func attachHosting() {
        addSubview(hosting)
        NSLayoutConstraint.activate(edges)
    }

    /// Runs `body` with the hosting view in this view, laid out: while gated it comes in for `body` and
    /// leaves after, so a snapshot (hibernation, a preview) draws the page as it is now. The page is
    /// parked hidden meanwhile, so nothing shows.
    public func withHosting<T>(_ body: () -> T) -> T {
        guard isGated else { return body() }
        attachHosting()
        defer { hosting.removeFromSuperview() }
        // sync-layout: a snapshot draws in this call, and the hosting view just came back unlaid out.
        layoutSubtreeIfNeeded()
        return body()
    }
}

/// A page's content view that holds a ``VisibilityGatedHostingView`` (the tab's node drives it), or
/// returns nil and says why at its conformance.
@MainActor public protocol VisibilityGatedContent: NSView {
    /// The gate the tab's visibility node drives.
    var visibilityGate: VisibilityGatedHostingView? { get }
}

extension NSView {
    /// The subviews, with a gated hosting view while it is out of the hierarchy: a walk for a page's
    /// scroll position or its views finds them in a hidden page too.
    public var subviewsIncludingGated: [NSView] {
        if let gate = self as? VisibilityGatedHostingView, gate.isGated { return subviews + [gate.hosting] }
        return subviews
    }

    /// This view as it draws now (`cacheDisplay`), a gated page's SwiftUI included
    /// (``VisibilityGatedHostingView/withHosting(_:)``); nil at no size.
    public func cachedDisplayImage() -> CGImage? {
        let draw = { () -> CGImage? in
            guard !self.bounds.isEmpty, let rep = self.bitmapImageRepForCachingDisplay(in: self.bounds) else { return nil }
            self.cacheDisplay(in: self.bounds, to: rep)
            return rep.cgImage
        }
        guard let gate = (self as? any VisibilityGatedContent)?.visibilityGate else { return draw() }
        return gate.withHosting(draw)
    }
}
