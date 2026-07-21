import Combine
import Observation
import SwiftUI

/// Canonical storage for interactive sidebar geometry, owned outside
/// ContentView's state so width ticks do not re-evaluate the whole window
/// body.
///
/// ContentView holds this model without reading `width` in its body; the
/// only view bodies that read it are the tiny applier wrappers below, so a
/// divider drag re-evaluates just those wrappers (a frame/padding
/// re-application over an already-built content value) instead of the
/// god-body. Reads that happen outside view bodies (session save, clamping,
/// resizer math in event-handler closures) register no Observation
/// dependency.
@MainActor
@Observable
final class SidebarLayoutModel {
    /// Legacy Combine bridge for the remaining `.$width` subscriber
    /// (ContentView's queue-hopped settle pipeline, which must stay
    /// onReceive: an onChange(of: width) would register the god-body
    /// dependency this model exists to avoid). Emits the new value during
    /// willSet and replays the current value on subscribe — the exact
    /// `Published.Publisher` semantics that call site was written against.
    @ObservationIgnored let widthPublisher: CurrentValueSubject<CGFloat, Never>
    var width: CGFloat {
        willSet { widthPublisher.send(newValue) }
    }

    init(width: CGFloat) {
        self.width = width
        self.widthPublisher = CurrentValueSubject(width)
    }
}

/// Re-evaluates only its own body when the width changes: the parent builds
/// this once, and width ticks re-invoke `content` with the fresh value
/// without touching the parent's body. Consumers that need the numeric
/// width (panel builders, padding, resizer math) read it as the closure
/// parameter.
struct SidebarWidthReader<Content: View>: View {
    let layout: SidebarLayoutModel
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(layout.width)
    }
}

/// `.frame(width:)` from the layout model as a modifier, for sites where the
/// content is already built and only the width application must track ticks.
struct SidebarWidthFrameModifier: ViewModifier {
    let layout: SidebarLayoutModel

    func body(content: Content) -> some View {
        content.frame(width: layout.width)
    }
}

/// `.padding(.leading:)` from the layout model as a modifier: the content
/// value stays as built by the parent (the terminal subtree is expensive to
/// re-construct per tick); only the padding application tracks width.
struct SidebarWidthLeadingPaddingModifier: ViewModifier {
    let layout: SidebarLayoutModel
    let enabled: Bool

    func body(content: Content) -> some View {
        content.padding(.leading, enabled ? layout.width : 0)
    }
}
