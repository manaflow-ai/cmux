public import AppKit

/// Resolves the sidebar list's enclosing `NSScrollView` for the SwiftUI layer
/// (``SidebarScrollViewResolver``), which applies the sidebar configuration in
/// ``AppKit/NSScrollView/applySidebarScrollIndicatorConfiguration()`` through
/// `onResolve`.
public final class SidebarScrollViewResolverView: NSView {
  /// Invoked with the resolved enclosing scroll view (or `nil`) after each
  /// deferred resolution hop.
  public var onResolve: ((NSScrollView?) -> Void)?
  private var pendingResolutionTask: Task<Void, Never>?

  deinit {
    pendingResolutionTask?.cancel()
  }

  /// Cancels stale deferred resolution when the resolver is reparented.
  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    cancelPendingResolution()
    resolveScrollView()
  }

  /// Cancels stale deferred resolution when the resolver changes windows.
  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    cancelPendingResolution()
    resolveScrollView()
  }

  /// Resolves the enclosing scroll view after one deferred main-actor hop so
  /// the view hierarchy settles before the configuration is applied.
  public func resolveScrollView() {
    // Coalesce repeated SwiftUI updates into one deferred hierarchy walk.
    pendingResolutionTask?.cancel()
    pendingResolutionTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      pendingResolutionTask = nil
      onResolve?(resolveNearestScrollView())
    }
  }

  /// SwiftUI places a representable used as a scroll view background beside
  /// its `HostingScrollView`, rather than inside it. Walk only as far as the
  /// first shared ancestor containing a scroll view at this resolver's
  /// layout point, which avoids selecting unrelated window scroll views.
  private func resolveNearestScrollView() -> NSScrollView? {
    if let enclosingScrollView {
      return enclosingScrollView
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
        return scrollView
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

  private func cancelPendingResolution() {
    pendingResolutionTask?.cancel()
    pendingResolutionTask = nil
  }
}
