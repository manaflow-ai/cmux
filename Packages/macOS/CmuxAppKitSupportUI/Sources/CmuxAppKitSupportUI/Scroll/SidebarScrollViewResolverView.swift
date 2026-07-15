public import AppKit

/// Resolves the sidebar list's enclosing `NSScrollView` for the SwiftUI layer
/// (``SidebarScrollViewResolver``), which applies the sidebar configuration in
/// ``AppKit/NSScrollView/applySidebarScrollIndicatorConfiguration()`` through
/// `onResolve`.
public final class SidebarScrollViewResolverView: NSView {
  /// Invoked with the resolved enclosing scroll view (or `nil`) after each
  /// deferred resolution hop.
  public var onResolve: ((NSScrollView?) -> Void)?
  private weak var resolvedScrollView: NSScrollView?
  private weak var resolutionAncestor: NSView?
  private var pendingResolutionTask: Task<Void, Never>?

  deinit {
    pendingResolutionTask?.cancel()
  }

  /// Invalidates the cached hierarchy match when the resolver is reparented.
  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    invalidateResolution()
    resolveScrollView()
  }

  /// Invalidates the cached hierarchy match when the resolver changes windows.
  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    invalidateResolution()
    resolveScrollView()
  }

  /// Resolves the enclosing scroll view after one deferred main-actor hop so
  /// the view hierarchy settles before the configuration is applied.
  public func resolveScrollView() {
    if let cachedScrollView = cachedScrollViewIfValid() {
      onResolve?(cachedScrollView)
      return
    }

    // Coalesce repeated SwiftUI updates into one deferred hierarchy walk.
    pendingResolutionTask?.cancel()
    pendingResolutionTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      pendingResolutionTask = nil
      let resolution = resolveNearestScrollView()
      resolvedScrollView = resolution?.scrollView
      resolutionAncestor = resolution?.ancestor
      onResolve?(resolution?.scrollView)
    }
  }

  /// SwiftUI places a representable used as a scroll view background beside
  /// its `HostingScrollView`, rather than inside it. Walk only as far as the
  /// first shared ancestor containing a scroll view at this resolver's
  /// layout point, which avoids selecting unrelated window scroll views.
  private func resolveNearestScrollView() -> (scrollView: NSScrollView, ancestor: NSView)? {
    if let enclosingScrollView {
      return (enclosingScrollView, enclosingScrollView)
    }

    var ancestor = superview
    while let currentAncestor = ancestor {
      let resolverPoint = convert(
        NSPoint(x: bounds.midX, y: bounds.midY),
        to: currentAncestor
      )
      let result = descendantScrollView(in: currentAncestor, containing: resolverPoint)
      if result.isAmbiguous {
        return nil
      }
      if let scrollView = result.scrollView {
        return (scrollView, currentAncestor)
      }
      ancestor = currentAncestor.superview
    }
    return nil
  }

  private func descendantScrollView(
    in view: NSView,
    containing point: NSPoint
  ) -> (scrollView: NSScrollView?, isAmbiguous: Bool) {
    var match: NSScrollView?
    var isAmbiguous = false

    func visit(_ currentView: NSView) {
      for subview in currentView.subviews {
        if let scrollView = subview as? NSScrollView,
          scrollView.bounds.contains(scrollView.convert(point, from: view))
        {
          if match != nil {
            isAmbiguous = true
            return
          }
          match = scrollView
        }
        visit(subview)
        if isAmbiguous { return }
      }
    }

    visit(view)
    return (match, isAmbiguous)
  }

  private func cachedScrollViewIfValid() -> NSScrollView? {
    guard let resolvedScrollView,
      let resolutionAncestor,
      self === resolutionAncestor || isDescendant(of: resolutionAncestor),
      resolvedScrollView === resolutionAncestor
        || resolvedScrollView.isDescendant(of: resolutionAncestor)
    else {
      invalidateResolution()
      return nil
    }
    return resolvedScrollView
  }

  private func invalidateResolution() {
    pendingResolutionTask?.cancel()
    pendingResolutionTask = nil
    resolvedScrollView = nil
    resolutionAncestor = nil
  }
}
