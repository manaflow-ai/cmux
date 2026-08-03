public import AppKit

/// Native resolver for an enclosing sidebar scroll view.
public typealias SidebarScrollViewResolver = SidebarScrollViewResolverView

public extension SidebarScrollViewResolverView {
    /// Creates a resolver that reports its enclosing scroll view.
    convenience init(onResolve: @escaping (NSScrollView?) -> Void) {
        self.init(frame: .zero)
        self.onResolve = onResolve
    }
}
