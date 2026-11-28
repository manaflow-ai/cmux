import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Live, reference-typed presence flags shared between probe islands. UIKit
/// callbacks read and write these directly at event time; SwiftUI closure
/// captures of value state would go stale between renders and misreport
/// during navigation transitions.
@MainActor
final class WorkspaceBarPresence {
    /// Whether the detail screen's content view is attached to a window.
    /// False during whole-screen detachments (a deeper push, a pop, scene
    /// teardown), when toolbar probes also detach for lifecycle reasons that
    /// have nothing to do with the overflow More menu.
    var detailContentAttached = false
}

extension View {
    /// Tracks whether this view's content is attached to a UIKit window,
    /// writing into the shared presence object in real time.
    @ViewBuilder
    func trackBarPresence(_ presence: WorkspaceBarPresence) -> some View {
        #if canImport(UIKit)
        background(ContentPresenceReader(presence: presence))
        #else
        self
        #endif
    }

    /// Reports this trailing toolbar item's rendered content width into the
    /// shared measurement dictionary, and optionally reports when the item's
    /// content leaves the window while still structurally present.
    ///
    /// The leading title menu caps its width to the bar's remaining space so
    /// the trailing items are never squeezed into the More menu. Width
    /// entries are deliberately never removed on disappear: overflowing into
    /// More also removes the bar content, so clearing the width there would
    /// release the reservation and make the collapse sticky. Callers that
    /// structurally remove an item clear its key from the condition that
    /// removed it.
    ///
    /// `onLeaveBar` is only wired for items that are always structurally
    /// present, and the callback must gate on the screen's content still
    /// being attached (`WorkspaceBarPresence`): a whole-screen detachment
    /// (deeper push, pop) also detaches this probe and is indistinguishable
    /// from a More-menu collapse at this level.
    @ViewBuilder
    func measureTrailingToolbarItem(
        _ key: String,
        into widths: Binding<[String: CGFloat]>,
        onLeaveBar: (@MainActor () -> Void)? = nil
    ) -> some View {
        let measured = onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            widths.wrappedValue[key] = width
        }
        #if canImport(UIKit)
        measured.background(BarPresenceReader(probeKey: key, onLeaveBar: onLeaveBar))
        #else
        measured
        #endif
    }
}

#if canImport(UIKit)
private struct ContentPresenceReader: UIViewRepresentable {
    let presence: WorkspaceBarPresence

    func makeUIView(context: Context) -> ContentPresenceProbeView {
        let view = ContentPresenceProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.presence = presence
        return view
    }

    func updateUIView(_ view: ContentPresenceProbeView, context: Context) {
        view.presence = presence
    }
}

final class ContentPresenceProbeView: UIView {
    var presence: WorkspaceBarPresence?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let attached = window != nil
        MainActor.assumeIsolated {
            presence?.detailContentAttached = attached
        }
    }
}

/// Bridges out of the SwiftUI hosting island to observe whether the item's
/// content is attached to a UIKit window. Detaching after having been
/// attached, while the screen's own content stays on a window, is the
/// observable signature of the system moving the item into the overflow More
/// menu; the caller supplies that content-presence gate.
private struct BarPresenceReader: UIViewRepresentable {
    let probeKey: String
    let onLeaveBar: (@MainActor () -> Void)?

    func makeUIView(context: Context) -> BarPresenceProbeView {
        let view = BarPresenceProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.probeKey = probeKey
        view.onLeaveBar = onLeaveBar
        return view
    }

    func updateUIView(_ view: BarPresenceProbeView, context: Context) {
        view.onLeaveBar = onLeaveBar
    }
}

final class BarPresenceProbeView: UIView {
    var probeKey = ""
    var onLeaveBar: (@MainActor () -> Void)?
    private var wasAttached = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if DEBUG
        NSLog(
            "cmux.toolbar.collapse probe key=%@ attached=%d",
            probeKey, window == nil ? 0 : 1
        )
        #endif
        if window != nil {
            wasAttached = true
            return
        }
        guard wasAttached else { return }
        wasAttached = false
        MainActor.assumeIsolated {
            onLeaveBar?()
        }
    }
}
#endif
