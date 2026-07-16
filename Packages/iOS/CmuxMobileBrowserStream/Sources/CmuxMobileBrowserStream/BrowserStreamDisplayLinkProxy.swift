#if canImport(UIKit)
import QuartzCore

/// Weak display-link target that does not retain the browser content view.
@MainActor
final class BrowserStreamDisplayLinkProxy {
    weak var target: BrowserStreamContentView?

    init(target: BrowserStreamContentView) {
        self.target = target
    }

    @objc func fire() {
        target?.flushPendingScroll()
    }
}
#endif
