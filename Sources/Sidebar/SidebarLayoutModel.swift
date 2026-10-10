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
    /// Whether the docked layout gives the sidebar its width (terminal
    /// inset, pane in its slot). Mirrors `SidebarState.isVisible`, except
    /// that the toggle animator flips it first: only the small wrappers
    /// below read it, so the keypress frame of a toggle never re-evaluates
    /// ContentView's body. While false, the pane stays laid out at full
    /// width, parked just past the window's leading edge.
    @Published var docksSidebar = true
    /// The docked pane's host, so the toggle animator can start row
    /// animations at a show's first frame without a SwiftUI pass.
    weak var dockedPane: SidebarDockedPaneHost.ContainerView?
    /// The titlebar title's host, which the toggle's slide glides between
    /// its hidden and docked resting x.
    weak var titlebarTitle: SidebarSlideGlideHost.ContainerView?

    /// How far the window ground reaches past the leading edge, so a toggle
    /// slide (which translates the content root by up to the sidebar width)
    /// never uncovers the window edge. Static: nothing re-lays out per slide.
    static let groundBleed = CGFloat(SessionPersistencePolicy.maximumSidebarWidth)

    init(width: CGFloat) {
        self.width = width
    }
}

/// Re-evaluates only its own body when the width changes: the parent builds
/// this once, and width ticks re-invoke `content` with the fresh value
/// without touching the parent's body. Consumers that need the numeric
/// width (panel builders, padding, resizer math) read it as the closure
/// parameter.
struct SidebarWidthReader<Content: View>: View {
    @ObservedObject var layout: SidebarLayoutModel
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(layout.width)
    }
}

/// `.frame(width:)` from the layout model as a modifier, for sites where the
/// content is already built and only the width application must track ticks.
struct SidebarWidthFrameModifier: ViewModifier {
    @ObservedObject var layout: SidebarLayoutModel

    func body(content: Content) -> some View {
        // A sidebar row may be wider than the pane (for example an authored
        // custom row using `.fixedSize()`). Keep that overflow attached to
        // the leading edge so the pane clips/truncates only at its trailing
        // edge instead of shifting every sibling left by the same amount.
        content.frame(width: layout.width, alignment: .leading)
    }
}

/// `.padding(.leading:)` from the layout model as a modifier: the content
/// value stays as built by the parent (the terminal subtree is expensive to
/// re-construct per tick); only the padding application tracks width.
struct SidebarWidthLeadingPaddingModifier: ViewModifier {
    @ObservedObject var layout: SidebarLayoutModel
    let enabled: Bool

    func body(content: Content) -> some View {
        content.padding(.leading, enabled && layout.docksSidebar ? layout.width : 0)
    }
}
