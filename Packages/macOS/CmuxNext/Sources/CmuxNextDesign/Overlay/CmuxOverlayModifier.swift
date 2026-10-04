public import SwiftUI
import AppKit

public extension View {
    /// Presents `content` on the window's `WindowOverlayHost` (above every
    /// Chromium page) while `isPresented` is true. With no anchor in
    /// `options`, tooltips, popovers and menus anchor on this view. A
    /// dismissal by the host (Escape) sets `isPresented` to false.
    func cmuxOverlay<Content: View>(isPresented: Binding<Bool>, options: OverlayOptions,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        background(CmuxOverlayAnchor(isPresented: isPresented, options: options, content: { AnyView(content()) }))
    }
}

private struct CmuxOverlayAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let options: OverlayOptions
    let content: () -> AnyView

    func makeCoordinator() -> CmuxOverlayCoordinator { CmuxOverlayCoordinator() }

    func makeNSView(context: Context) -> CmuxOverlayProbe {
        let probe = CmuxOverlayProbe()
        let coordinator = context.coordinator
        probe.onWindowChange = { [weak coordinator, weak probe] in
            if let probe { coordinator?.sync(probe) }
        }
        return probe
    }

    func updateNSView(_ view: CmuxOverlayProbe, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.options = options
        context.coordinator.content = content
        context.coordinator.sync(view)
    }

    static func dismantleNSView(_ view: CmuxOverlayProbe, coordinator: CmuxOverlayCoordinator) {
        coordinator.handle?.dismiss()
        coordinator.handle = nil
    }
}

/// Finds the window of the modified view (it may join one after its first update).
final class CmuxOverlayProbe: NSView {
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

final class CmuxOverlayCoordinator {
    var handle: OverlayHandle?
    var isPresented: Binding<Bool>?
    var options = OverlayOptions(kind: .popover)
    var content: (() -> AnyView)?

    func sync(_ view: NSView) {
        guard let isPresented, isPresented.wrappedValue, let window = view.window, let content else {
            if isPresented?.wrappedValue != true {
                handle?.dismiss()
                handle = nil
            }
            return
        }
        var options = options
        if options.anchor == nil, [.tooltip, .popover, .menu].contains(options.kind) {
            options.anchor = view.convert(view.bounds, to: nil)
        }
        if let handle, !handle.isDismissed {
            if let anchor = options.anchor { handle.update(anchor: anchor) }
            return
        }
        let hosting = NSHostingView(rootView: content())
        hosting.setFrameSize(hosting.fittingSize)
        let handle = WindowOverlayHost.host(for: window).present(hosting, options: options)
        handle.onDismiss = { [weak self] in
            self?.handle = nil
            if isPresented.wrappedValue { isPresented.wrappedValue = false }
        }
        self.handle = handle
    }
}
