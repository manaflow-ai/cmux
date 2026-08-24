import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Reports this trailing toolbar item's rendered content width into the
    /// shared measurement dictionary, and optionally reports when the item's
    /// content leaves the window while still structurally present, which on
    /// iOS means the system folded the item into the overflow More menu.
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
    /// present: a conditional item's structural removal also detaches its
    /// probe and would be indistinguishable from a collapse.
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
/// Bridges out of the SwiftUI hosting island to observe whether the item's
/// content is attached to a UIKit window. Detaching after having been
/// attached, while the SwiftUI view is still alive, is the observable
/// signature of the system moving the item into the overflow More menu.
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
