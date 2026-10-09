import AppKit
import CmuxSidebar
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
    /// What the content was built for. A park change alone skips the content
    /// push; a change here never does (a dock/float switch moves the park
    /// and the list's presentation in the same update).
    let isPresented: Bool
    /// On screen (not parked). The reveal's push waits a turn, so the
    /// landing frame stays as light as the keypress.
    let isRevealed: Bool
    let presentationMode: SidebarPresentationMode
    let layout: SidebarLayoutModel
    let content: AnyView

    final class ContainerView: NSView {
        let hostingView: NSHostingView<AnyView>
        fileprivate var parkedOffset: CGFloat = 0
        fileprivate var isPresented = false
        fileprivate var isRevealed = false
        fileprivate var presentationMode: SidebarPresentationMode = .docked
        fileprivate var deferredContent: AnyView?
        private weak var table: SidebarWorkspaceTableContainerView?

        /// Called by the toggle animator: rows animate from a show's first
        /// frame and pause once a hide lands. SwiftUI's `isRevealed` agrees
        /// after the landing.
        func setRowsOnScreen(_ onScreen: Bool) {
            if table == nil { table = Self.firstTable(in: hostingView) }
            table?.clipView.workspaceController?.setRowsOnScreen(onScreen)
        }

        private static func firstTable(in view: NSView) -> SidebarWorkspaceTableContainerView? {
            if let table = view as? SidebarWorkspaceTableContainerView { return table }
            return view.subviews.lazy.compactMap { firstTable(in: $0) }.first
        }

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
        view.isPresented = isPresented
        view.isRevealed = isRevealed
        view.presentationMode = presentationMode
        layout.dockedPane = view
        apply(parkedOffset, to: view)
        return view
    }

    func updateNSView(_ view: ContainerView, context: Context) {
        // A toggle's park or unpark changes nothing in the pane: move the
        // drawing and skip re-diffing the whole sidebar in the keypress and
        // landing frames. The next update pushes content as usual.
        let contentInputsChanged = view.isPresented != isPresented
            || view.presentationMode != presentationMode
        let parks = view.parkedOffset != parkedOffset
        if parks {
            apply(parkedOffset, to: view)
            if !contentInputsChanged {
                guard view.isRevealed != isRevealed else { return }
                // A show landing: one push, on the next turn.
                view.isRevealed = isRevealed
                let pending = view.deferredContent == nil
                view.deferredContent = content
                // Default mode only: the landing's commit spins the run loop
                // in event tracking mode, and this must not run inside it.
                if pending {
                    RunLoop.main.perform(inModes: [.default]) { [weak view] in
                        MainActor.assumeIsolated {
                            guard let view, let content = view.deferredContent else { return }
                            view.deferredContent = nil
                            view.hostingView.rootView = content
                        }
                    }
                }
                return
            }
        } else if view.deferredContent != nil, !contentInputsChanged, view.isRevealed == isRevealed {
            // The rest of the landing's update: ride the pending push.
            view.deferredContent = content
            return
        }
        view.deferredContent = nil
        view.isPresented = isPresented
        view.isRevealed = isRevealed
        view.presentationMode = presentationMode
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
