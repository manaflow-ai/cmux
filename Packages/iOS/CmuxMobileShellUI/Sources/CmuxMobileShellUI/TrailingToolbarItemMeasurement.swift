import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One trailing toolbar item's rendered content geometry.
///
/// Width comes from `onGeometryChange` (island-local sizes are correct) and
/// feeds the estimate-based reserve exactly as before. The leading edge is
/// measured separately in the shared UIKit window space, because each
/// `ToolbarItem` is bridged into the navigation bar as its own SwiftUI
/// hosting island and `.global` frames are not comparable across islands.
/// The edge is optional: the realized-span path only engages when every
/// structural item has one, and an item whose probe leaves the window (for
/// example, collapsed into the overflow More menu) clears its edge so the
/// span invalidates and the title falls back to the safe estimate reserve,
/// un-collapsing the bar.
struct TrailingToolbarItemGeometry: Equatable {
    /// Rendered content width (inside the glass capsule chrome).
    var width: CGFloat = 0
    /// Leading edge of the content in the window space, when known.
    var globalMinX: CGFloat?
}

extension View {
    /// Reports this trailing toolbar item's rendered content geometry into the
    /// shared measurement dictionary.
    ///
    /// The leading title menu caps its width to the bar's remaining space so
    /// the trailing items are never squeezed into the overflow More menu.
    /// Width entries are deliberately never removed on disappear: overflowing
    /// into More also removes the bar content, so clearing the width there
    /// would release the reservation and make the collapse sticky. Callers
    /// that structurally remove an item clear its key from the condition that
    /// removed it.
    func measureTrailingToolbarItem(
        _ key: String,
        into geometry: Binding<[String: TrailingToolbarItemGeometry]>
    ) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard geometry.wrappedValue[key]?.width != width else { return }
            geometry.wrappedValue[key, default: TrailingToolbarItemGeometry()].width = width
        }
        .measureWindowFrame(probeKey: key) { frame in
            guard geometry.wrappedValue[key]?.globalMinX != frame?.minX else { return }
            geometry.wrappedValue[key, default: TrailingToolbarItemGeometry()].globalMinX = frame?.minX
        }
    }

    /// Reports the fitted title label's frame in window space; the leading
    /// edge is stable under cap changes (the frame is leading-aligned).
    func measureToolbarTitleFrame(_ onChange: @escaping (CGRect?) -> Void) -> some View {
        measureWindowFrame(probeKey: "title", onChange)
    }

    /// `onChange` receives nil when the probe leaves the window (the content
    /// was removed from the bar, for example into the overflow More menu).
    @ViewBuilder
    private func measureWindowFrame(
        probeKey: String,
        _ onChange: @escaping (CGRect?) -> Void
    ) -> some View {
        #if canImport(UIKit)
        background(WindowFrameReader(probeKey: probeKey, onChange: onChange))
        #else
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            onChange(frame)
        }
        #endif
    }
}

#if canImport(UIKit)
/// Bridges out of the SwiftUI hosting island to read the probe's frame in the
/// shared UIKit window. Reports on layout, window attachment, and SwiftUI
/// updates, deduplicated; reports nil on window detachment.
private struct WindowFrameReader: UIViewRepresentable {
    let probeKey: String
    let onChange: (CGRect?) -> Void

    func makeUIView(context: Context) -> WindowFrameProbeView {
        let view = WindowFrameProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.probeKey = probeKey
        view.onChange = onChange
        #if DEBUG
        NSLog("cmux.toolbar.span probe-made key=%@", probeKey)
        #endif
        return view
    }

    func updateUIView(_ view: WindowFrameProbeView, context: Context) {
        view.onChange = onChange
        // SwiftUI updates land after the layout that moved this view; frames
        // are current here even when only an ancestor's position changed
        // (position-only moves do not call layoutSubviews on this leaf).
        view.reportIfChanged()
    }
}

final class WindowFrameProbeView: UIView {
    var probeKey = ""
    var onChange: ((CGRect?) -> Void)?
    private var lastReported: CGRect?

    override func layoutSubviews() {
        super.layoutSubviews()
        reportIfChanged()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if DEBUG
        NSLog(
            "cmux.toolbar.span probe-window key=%@ attached=%d",
            probeKey, window == nil ? 0 : 1
        )
        #endif
        if window == nil {
            // Removed from the bar (e.g. the system collapsed the item into
            // the More menu). Invalidate so the span consumer falls back.
            lastReported = nil
            onChange?(nil)
            return
        }
        reportIfChanged()
    }

    func reportIfChanged() {
        guard let window else { return }
        let frame = convert(bounds, to: window)
        guard frame != lastReported else { return }
        lastReported = frame
        #if DEBUG
        NSLog(
            "cmux.toolbar.span probe key=%@ minX=%.1f width=%.1f",
            probeKey, frame.minX, frame.width
        )
        #endif
        onChange?(frame)
    }
}
#endif
