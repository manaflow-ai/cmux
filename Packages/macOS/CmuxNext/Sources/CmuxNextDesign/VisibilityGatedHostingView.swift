public import AppKit
public import CmuxNextWakeups
public import SwiftUI

/// A tab content view that hosts SwiftUI and stops its graph work while the tab's node is hidden
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section B, task 214).
///
/// A parked page stays in the window (hidden), and SwiftUI keeps evaluating the bodies its model
/// changes invalidate. While the node it follows is hidden, this view takes its hosting view out of
/// the hierarchy and shows a picture of its last frame in its place; it puts the hosting view back in
/// the show turn, with the keyboard focus it held. Chromium does the same for a hidden WebContents:
/// `RenderWidgetHostImpl::WasHidden` stops the renderer's frames and the compositor keeps showing the
/// last surface (content/browser/renderer_host/render_widget_host_impl.cc).
///
/// An occluded node keeps its hosting view (Chrome's `OCCLUDED` keeps the renderer alive), and so does a
/// hidden node that a capture vote holds (``VisibilityNode/isCaptured``): a screenshot reads the live page.
///
/// Until ``follow(_:observations:)`` this is a plain container. A page that must keep its hosting view
/// while hidden says why with ``Policy/optOut(reason:)``; it still counts its bodies.
///
/// ```swift
/// let gate = VisibilityGatedHostingView(owner: "Tasks") { TasksView(model: model, layout: layout()) }
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

    private let counter: HostingBodyCounter
    private let picture = NSView()
    private var edges: [NSLayoutConstraint] = []
    private var node: VisibilityNode?
    private var flips: VisibilitySubscription?
    private var exemptions: VisibilitySubscription?
    private weak var ledger: ObservationLedger?
    /// The view inside the hosting view that had the keyboard when it left.
    private weak var focused: NSView?

    /// Hosts `content`, built in the root's body: the observable state it reads is the root's, and each
    /// evaluation counts (``bodyEvaluations``, `debug.observations`). Views below count themselves with
    /// `@Environment(\.hostingBodyCounter)`.
    public convenience init<Content: View>(owner: String, policy: Policy = .gated,
                                           @ViewBuilder content: @escaping @MainActor () -> Content) {
        let counter = HostingBodyCounter()
        self.init(owner: owner, policy: policy, counter: counter,
                  hosting: NSHostingView(rootView: HostingBodyCountedRoot(counter: counter, content: content)))
    }

    /// Gates a hosting view made elsewhere (an `NSHostingView` subclass that measures itself). Its bodies
    /// count only where its views read `\.hostingBodyCounter`.
    public convenience init(owner: String, policy: Policy = .gated, hosting: NSView) {
        self.init(owner: owner, policy: policy, counter: HostingBodyCounter(), hosting: hosting)
    }

    private init(owner: String, policy: Policy, counter: HostingBodyCounter, hosting: NSView) {
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
        picture.wantsLayer = true
        picture.layer?.contentsGravity = .resizeAspectFill
        picture.autoresizingMask = [.width, .height]
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
        if let image = lastFrame() {
            picture.layer?.contents = image
            picture.layer?.contentsScale = window?.backingScaleFactor ?? 2
            picture.frame = bounds
            addSubview(picture)
        }
        isGated = true
        hosting.removeFromSuperview()
    }

    private func restore() {
        guard isGated else { return }
        isGated = false
        addSubview(hosting, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate(edges)
        picture.removeFromSuperview()
        picture.layer?.contents = nil
        // The keyboard left with the hosting view only when nothing took it since (the window holds it).
        if let focused, let window, window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(focused)
        }
        focused = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The hosting view's layers as they show now, composited without drawing its views again; nil out of
    /// a window or at no size (nothing showed).
    private func lastFrame() -> CGImage? {
        guard let window, let layer = hosting.layer, !hosting.bounds.isEmpty else { return nil }
        let scale = window.backingScaleFactor
        let width = Int(hosting.bounds.width * scale), height = Int(hosting.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
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
}
