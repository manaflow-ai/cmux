#if canImport(UIKit)
import QuartzCore

/// Weak display-link target that does not retain the browser content view.
///
/// Owns the link's teardown: a `@MainActor` view cannot invalidate a
/// `CADisplayLink` from its nonisolated `deinit` under Swift 6, so the proxy
/// self-invalidates on the first tick after its target deallocates.
@MainActor
final class BrowserStreamDisplayLinkProxy {
    weak var target: BrowserStreamContentView?
    var link: CADisplayLink?

    init(target: BrowserStreamContentView) {
        self.target = target
    }

    @objc func fire() {
        guard let target else {
            link?.invalidate()
            link = nil
            return
        }
        target.flushPendingDisplayLinkWork()
    }
}
#endif
