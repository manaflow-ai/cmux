import Combine
import SwiftUI

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
final class SidebarLayoutModel: ObservableObject {
    @Published var width: CGFloat

    init(width: CGFloat) {
        self.width = width
    }
}

/// Applies `.frame(width:)` from the layout model to pre-built content.
/// The content value is constructed by the parent once per PARENT
/// re-evaluation; width ticks re-run only this wrapper's body.
struct SidebarWidthFrameApplier<Content: View>: View {
    @ObservedObject var layout: SidebarLayoutModel
    let content: Content

    var body: some View {
        content.frame(width: layout.width)
    }
}

/// Applies `.padding(.leading:)` from the layout model (withinWindow blend
/// mode offsets the terminal content under the overlapping sidebar).
struct SidebarWidthLeadingPaddingApplier<Content: View>: View {
    @ObservedObject var layout: SidebarLayoutModel
    let enabled: Bool
    let content: Content

    var body: some View {
        content.padding(.leading, enabled ? layout.width : 0)
    }
}
