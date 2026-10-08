import AppKit
import SwiftUI

/// Hosts the docked sidebar pane in its own AppKit view, always in its slot.
///
/// A hidden docked pane stays mounted (its table never cold-starts) and
/// must slide in already drawn. Parking it past the window's leading edge
/// with a layout offset does not work: AppKit clears the text of views it
/// considers outside the window and draws nothing for them until they come
/// back. So the pane never leaves its slot as far as AppKit knows; parking
/// and the toggle's slide move only what is drawn, with a render-only
/// `sublayerTransform` on this container. Hidden, the container passes
/// clicks through.
struct SidebarDockedPaneHost: NSViewRepresentable {
    /// How far left the pane's drawing is moved: 0 docked, its width parked.
    let parkedOffset: CGFloat
    let content: AnyView

    final class ContainerView: NSView {
        let hostingView: NSHostingView<AnyView>
        fileprivate var parkedOffset: CGFloat = 0

        init(content: AnyView) {
            hostingView = NSHostingView(rootView: content)
            super.init(frame: .zero)
            wantsLayer = true
            hostingView.sizingOptions = []
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = bounds
            addSubview(hostingView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            parkedOffset != 0 ? nil : super.hitTest(point)
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView(content: content)
        apply(parkedOffset, to: view)
        return view
    }

    func updateNSView(_ view: ContainerView, context: Context) {
        // A toggle's park or unpark changes nothing in the pane: move the
        // drawing and skip re-diffing the whole sidebar in the keypress and
        // landing frames. The next update pushes content as usual.
        if view.parkedOffset != parkedOffset {
            apply(parkedOffset, to: view)
            return
        }
        view.hostingView.rootView = content
    }

    private func apply(_ offset: CGFloat, to view: ContainerView) {
        view.parkedOffset = offset
        let transform = CATransform3DMakeTranslation(-offset, 0, 0)
        guard let layer = view.layer, !CATransform3DEqualToTransform(layer.sublayerTransform, transform) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = transform
        CATransaction.commit()
    }
}
