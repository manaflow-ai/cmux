import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One trailing toolbar item's rendered content geometry.
///
/// Positions are measured in the UIKit window space: each `ToolbarItem` is
/// bridged into the navigation bar as its own SwiftUI hosting island, so
/// SwiftUI's `.global` space resolves per-island and cross-item math needs
/// the shared window. Values carry no width epoch: the span consumer rejects
/// measurements implausible for the current pane width (a stale wider-layout
/// edge lands past the pane's end), and stale narrower-layout values only
/// under-size the title, which is safe.
struct TrailingToolbarItemGeometry: Equatable {
    /// Rendered content width (inside the glass capsule chrome).
    var width: CGFloat
    /// Leading edge of the content in the window space.
    var globalMinX: CGFloat
}

extension View {
    /// Reports this trailing toolbar item's rendered content geometry into the
    /// shared measurement dictionary.
    ///
    /// The leading title menu caps its width to the bar's remaining space so
    /// the trailing items are never squeezed into the overflow More menu.
    /// Deliberately no removal on disappear: overflowing into More also
    /// removes the bar content, so clearing on disappear would release the
    /// reservation and make the collapse sticky. Callers that structurally
    /// remove an item clear its key from the condition that removed it.
    func measureTrailingToolbarItem(
        _ key: String,
        into geometry: Binding<[String: TrailingToolbarItemGeometry]>
    ) -> some View {
        measureWindowFrame { frame in
            let next = TrailingToolbarItemGeometry(
                width: frame.width,
                globalMinX: frame.minX
            )
            guard geometry.wrappedValue[key] != next else { return }
            geometry.wrappedValue[key] = next
            #if DEBUG
            NSLog(
                "cmux.toolbar.span probe key=%@ minX=%.1f width=%.1f",
                key, frame.minX, frame.width
            )
            #endif
        }
    }

    /// Reports the fitted title label's frame in window space; the leading
    /// edge is stable under cap changes (the frame is leading-aligned).
    func measureToolbarTitleFrame(_ onChange: @escaping (CGRect) -> Void) -> some View {
        measureWindowFrame(onChange)
    }

    @ViewBuilder
    private func measureWindowFrame(_ onChange: @escaping (CGRect) -> Void) -> some View {
        #if canImport(UIKit)
        background(WindowFrameReader(onChange: onChange))
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
/// shared UIKit window. Reports on layout and window attachment, deduplicated.
private struct WindowFrameReader: UIViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeUIView(context: Context) -> WindowFrameProbeView {
        let view = WindowFrameProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
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
    var onChange: ((CGRect) -> Void)?
    private var lastReported: CGRect?

    override func layoutSubviews() {
        super.layoutSubviews()
        reportIfChanged()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportIfChanged()
    }

    func reportIfChanged() {
        guard let window else { return }
        let frame = convert(bounds, to: window)
        guard frame != lastReported else { return }
        lastReported = frame
        onChange?(frame)
    }
}
#endif
