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
    @Published var leadingColumnWidth: CGFloat
    @Published var width: CGFloat

    init(
        width: CGFloat,
        leadingColumnWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarLeadingColumnWidth)
    ) {
        self.width = width
        self.leadingColumnWidth = leadingColumnWidth
    }

    var regionWidth: CGFloat {
        max(0, leadingColumnWidth) + max(0, width)
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

/// Re-evaluates only its wrapper when either column changes and exposes the
/// full sidebar-region width.
struct SidebarRegionWidthReader<Content: View>: View {
    @ObservedObject var layout: SidebarLayoutModel
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(layout.regionWidth)
    }
}

/// Exposes both independently persisted column widths without invalidating
/// ContentView's expensive terminal subtree on divider ticks.
struct SidebarColumnWidthsReader<Content: View>: View {
    @ObservedObject var layout: SidebarLayoutModel
    @ViewBuilder let content: (_ leading: CGFloat, _ primary: CGFloat, _ total: CGFloat) -> Content

    var body: some View {
        content(layout.leadingColumnWidth, layout.width, layout.regionWidth)
    }
}

/// `.frame(width:)` from the layout model as a modifier, for sites where the
/// content is already built and only the width application must track ticks.
struct SidebarWidthFrameModifier: ViewModifier {
    @ObservedObject var layout: SidebarLayoutModel

    func body(content: Content) -> some View {
        content.frame(width: layout.width)
    }
}

/// `.padding(.leading:)` from the layout model as a modifier: the content
/// value stays as built by the parent (the terminal subtree is expensive to
/// re-construct per tick); only the padding application tracks width.
struct SidebarWidthLeadingPaddingModifier: ViewModifier {
    @ObservedObject var layout: SidebarLayoutModel
    let enabled: Bool

    func body(content: Content) -> some View {
        content.padding(.leading, enabled ? layout.width : 0)
    }
}

/// Leading padding for the complete multi-column sidebar region.
struct SidebarRegionWidthLeadingPaddingModifier: ViewModifier {
    @ObservedObject var layout: SidebarLayoutModel
    let enabled: Bool

    func body(content: Content) -> some View {
        content.padding(.leading, enabled ? layout.regionWidth : 0)
    }
}
