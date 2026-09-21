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
    private let group: CmuxPopoverGroup?
    @ViewBuilder public let content: () -> PopoverContent

    /// Creates an arrowless popover anchor.
    /// - Parameters:
    ///   - isPresented: Binding driving popover presentation.
    ///   - preferredEdge: The edge of the anchor the popover prefers to appear from.
    ///   - detachedGap: The gap, in points, between the anchor edge and the popover.
    ///   - group: Shared dismissal owner when this popover belongs to a nested menu.
    ///   - content: The SwiftUI content rendered inside the popover.
    public init(
        isPresented: Binding<Bool>,
        preferredEdge: NSRectEdge,
        detachedGap: CGFloat,
        group: CmuxPopoverGroup? = nil,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) {
        self._isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.detachedGap = detachedGap
        self.group = group
        self.content = content
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchorView = nsView
        coordinator.updatePresentationBinding($isPresented)
        switch ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: isPresented,
            popoverIsShown: coordinator.isPopoverShown
        ) {
        case .none:
            coordinator.cancelDeferredRootViewUpdate()
        case .immediate:
            coordinator.updateRootView(AnyView(content()))
        case .deferredVisible:
            coordinator.deferVisibleRootViewUpdate(AnyView(content()))
        }

        if isPresented {
            coordinator.present(
                preferredEdge: preferredEdge,
                detachedGap: detachedGap
            )
        } else {
            coordinator.dismiss()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, group: group)
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss(resetPresentation: false)
    }

    /// Bridges popover lifecycle between AppKit's `NSPopover` and the SwiftUI binding.
    @MainActor
    public final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
        private var popover: NSPopover?
        private var closingPopovers: [ObjectIdentifier: NSPopover] = [:]
        private var pendingVisibleRootView: AnyView?
        private let group: CmuxPopoverGroup?
        private var groupMemberID: UUID?
        var isPopoverShown: Bool { popover?.isShown == true }

        init(isPresented: Binding<Bool>, group: CmuxPopoverGroup?) {
            _isPresented = isPresented
            self.group = group
        }

        func updatePresentationBinding(_ binding: Binding<Bool>) {
            _isPresented = binding
        }

        /// Returns whether this coordinator should use AppKit's presentation transition.
        ///
        /// Root popovers retain the native transition; nested popovers open immediately
        /// so the grouped hover path does not animate an independent child window.
        func shouldAnimatePresentation(reduceMotion: Bool, isSubmenu: Bool) -> Bool {
            !reduceMotion && !isSubmenu
        }

        func updateRootView(_ rootView: AnyView) {
            CmuxPopoverMutation.performWithoutImplicitAnimation {
                hostingController.rootView = AnyView(rootView.fixedSize())
                hostingController.view.invalidateIntrinsicContentSize()
                hostingController.view.layoutSubtreeIfNeeded()
            }
        }

        func deferVisibleRootViewUpdate(_ rootView: AnyView) {
            pendingVisibleRootView = rootView
            visibleUpdateScheduler.schedule { [weak self] in
                self?.flushDeferredRootViewUpdate()
            }
        }

        func cancelDeferredRootViewUpdate() {
            pendingVisibleRootView = nil
            visibleUpdateScheduler.cancel()
        }

        private func flushDeferredRootViewUpdate() {
            guard popover?.isShown == true, let pendingVisibleRootView else {
                self.pendingVisibleRootView = nil
                return
            }
            self.pendingVisibleRootView = nil
            updateRootView(pendingVisibleRootView)
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
                CmuxPopoverMutation.setContentSize(NSSize(
                    width: ceil(fittingSize.width),
                    height: ceil(fittingSize.height)
                ), on: popover)
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
            if popover.isShown {
                groupMemberID = group?.register(popover: popover, anchor: anchorView)
            }
        }

        func dismiss(resetPresentation: Bool = true) {
            cancelDeferredRootViewUpdate()
            unregisterFromGroup()
            guard let popover = self.popover else {
                if resetPresentation { isPresented = false }
                return
            }
            closingPopovers[ObjectIdentifier(popover)] = popover
            if group != nil { popover.animates = false }
            popover.performClose(nil)
            self.popover = nil
            if resetPresentation { isPresented = false }
        }

        public func popoverWillClose(_ notification: Notification) {
            guard let closing = notification.object as? NSPopover,
                  closing === popover || closingPopovers[ObjectIdentifier(closing)] != nil else { return }
            if closing === popover {
                unregisterFromGroup()
            }
        }

        private func unregisterFromGroup() {
            guard let id = groupMemberID else { return }
            groupMemberID = nil
            group?.unregister(id)
        }

        public func popoverDidClose(_ notification: Notification) {
            guard let closing = notification.object as? NSPopover else { return }
            if closingPopovers.removeValue(forKey: ObjectIdentifier(closing)) != nil {
                return
            }
            guard closing === popover else { return }
            cancelDeferredRootViewUpdate()
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = group == nil ? .semitransient : .applicationDefined
            // Grouping owns dismissal, not the root menu's native opening transition.
            // Hover submenus still open immediately, and Reduce Motion always wins.
            let isSubmenu = anchorView.flatMap { group?.parentID(for: $0) } != nil
            popover.animates = shouldAnimatePresentation(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                isSubmenu: isSubmenu
            )
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
