#if canImport(UIKit)
import UIKit

#if DEBUG
/// Off-screen accessibility carrier that reports ``GhosttySurfaceView``'s live
/// bottom-dock state to UI tests. Computes ``accessibilityValue`` on every read
/// (delegating to ``GhosttySurfaceView/composerDockProbeValue``) so an XCUITest
/// predicate-wait converges on the SETTLED post-transition state even though
/// `fieldFocused`/`proxyFirstResponder` flip a runloop after the synchronous
/// transition. DEBUG-only; never compiled into a shipping build.
final class ComposerDockProbeView: UIView {
    /// The surface whose dock state this probe re-reads on every query.
    weak var surface: GhosttySurfaceView?

    override var accessibilityValue: String? {
        get { surface?.composerDockProbeValue }
        set { /* read-only live probe; ignore writes */ }
    }
}
#endif
#endif
