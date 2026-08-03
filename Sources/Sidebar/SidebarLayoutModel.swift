import CoreGraphics
import Observation

/// Canonical storage for interactive sidebar geometry, owned outside
/// ContentView's state so width ticks do not re-evaluate the whole window
/// body.
///
/// ContentView holds this model UNOBSERVED (no @ObservedObject); the only
/// views that observe it are the tiny applier wrappers below, so a divider
/// drag re-evaluates just those wrappers (a frame/padding re-application
/// over an already-built content value) instead of the god-body. Reads that
/// happen outside view bodies (session save, clamping, resizer math) go
/// through `width` directly and register no dependency.
@MainActor
@Observable
final class SidebarLayoutModel {
    var width: CGFloat

    init(width: CGFloat) {
        self.width = width
    }
}
