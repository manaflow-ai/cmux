public import AppKit
public import SwiftUI

/// An `NSViewRepresentable` that presents SwiftUI content in an `NSPopover` with the
/// popover arrow hidden, anchored to an invisible SwiftUI-backed view.
///
/// The popover is positioned relative to a synthetic rect inset toward the anchor so the
/// detached content sits a fixed gap from the anchoring edge while the arrow stays hidden.
public struct ArrowlessPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding public var isPresented: Bool
    public let preferredEdge: NSRectEdge
    public let detachedGap: CGFloat
    @ViewBuilder public let content: () -> PopoverContent

    /// Creates an arrowless popover anchor.
    /// - Parameters:
    ///   - isPresented: Binding driving popover presentation.
    ///   - preferredEdge: The edge of the anchor the popover prefers to appear from.
    ///   - detachedGap: The gap, in points, between the anchor edge and the popover.
    ///   - content: The SwiftUI content rendered inside the popover.
    public init(
        isPresented: Binding<Bool>,
        preferredEdge: NSRectEdge,
        detachedGap: CGFloat,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) {
        self._isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.detachedGap = detachedGap
        self.content = content
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.updateRootView(AnyView(content()))

        if isPresented {
            context.coordinator.present(
                preferredEdge: preferredEdge,
                detachedGap: detachedGap
            )
        } else {
            context.coordinator.dismiss()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    /// Bridges popover lifecycle between AppKit's `NSPopover` and the SwiftUI binding.
    @MainActor
    public final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            hostingController.rootView = AnyView(rootView.fixedSize())
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
        }

        func present(preferredEdge: NSRectEdge, detachedGap: CGFloat) {
            guard let anchorView else {
                isPresented = false
                dismiss()
                return
            }

            let popover = popover ?? makePopover()
            if popover.isShown {
                return
            }

            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            let fittingSize = hostingController.view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                popover.contentSize = NSSize(
                    width: ceil(fittingSize.width),
                    height: ceil(fittingSize.height)
                )
            }

            popover.show(
                relativeTo: positioningRect(
                    for: anchorView.bounds,
                    preferredEdge: preferredEdge,
                    detachedGap: detachedGap
                ),
                of: anchorView,
                preferredEdge: preferredEdge
            )
        }

        func dismiss() {
            popover?.performClose(nil)
            popover = nil
        }

        public func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = true
            popover.setValue(true, forKeyPath: "shouldHideAnchor")
            popover.contentViewController = hostingController
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func positioningRect(
            for bounds: CGRect,
            preferredEdge: NSRectEdge,
            detachedGap: CGFloat
        ) -> CGRect {
            let hiddenArrowInset: CGFloat = 13
            let compensation = max(hiddenArrowInset - detachedGap, 0)

            switch preferredEdge {
            case .maxY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.maxY - compensation,
                    width: bounds.width,
                    height: compensation
                )
            case .minY:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: compensation
                )
            case .maxX:
                return NSRect(
                    x: bounds.maxX - compensation,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            case .minX:
                return NSRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: compensation,
                    height: bounds.height
                )
            @unknown default:
                return bounds
            }
        }
    }
}
