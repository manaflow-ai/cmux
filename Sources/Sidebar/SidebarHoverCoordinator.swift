import AppKit

@MainActor
final class SidebarHoverCoordinator {
    private struct Registration {
        weak var view: NSView?
        let setHovered: @MainActor (Bool) -> Void
    }

    weak var containerView: SidebarHoverContainerView? {
        didSet {
            guard containerView !== oldValue else { return }
            updateScrollObservation()
            reconcileCurrentPointer()
        }
    }

    private var registrations: [UUID: Registration] = [:]
    private var hoveredRowID: UUID? {
        didSet {
            guard hoveredRowID != oldValue else { return }
            if let oldValue,
               let registration = registrations[oldValue] {
                registration.setHovered(false)
            }
            if let hoveredRowID,
               let registration = registrations[hoveredRowID] {
                registration.setHovered(true)
            }
        }
    }
    private var reconcileScheduled = false
    private weak var observedClipView: NSClipView?
    private var clipBoundsObserver: NSObjectProtocol?

    func registerRowView(
        _ view: NSView,
        rowID: UUID,
        setHovered: @escaping @MainActor (Bool) -> Void
    ) {
        registrations[rowID] = Registration(
            view: view,
            setHovered: setHovered
        )
        setHovered(hoveredRowID == rowID)
        scheduleReconcileCurrentPointer()
    }

    func unregisterRowView(_ view: NSView, rowID: UUID) {
        guard registrations[rowID]?.view === view else { return }
        registrations.removeValue(forKey: rowID)
        if hoveredRowID == rowID {
            hoveredRowID = nil
        }
    }

    func rowViewFrameDidChange(_ view: NSView, rowID: UUID) {
        guard registrations[rowID]?.view === view else { return }
        scheduleReconcileCurrentPointer()
    }

    func pointerExitedContainer() {
        hoveredRowID = nil
    }

    func clearHover() {
        hoveredRowID = nil
    }

    func reconcileCurrentPointer() {
        guard let containerView,
              let window = containerView.window,
              window.isVisible,
              NSApp.isActive else {
            hoveredRowID = nil
            return
        }

        let pointInContainer = containerView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoveredRowID = hoveredRowID(at: pointInContainer)
    }

    private func scheduleReconcileCurrentPointer() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconcileScheduled = false
            self.reconcileCurrentPointer()
        }
    }

    private func hoveredRowID(at pointInContainer: NSPoint) -> UUID? {
        for (rowID, registration) in registrations {
            guard let view = registration.view,
                  let containerView,
                  view.window === containerView.window,
                  view.superview != nil,
                  !view.isHidden,
                  view.alphaValue > 0 else {
                continue
            }
            let frameInContainer = view.convert(view.bounds, to: containerView)
            if frameInContainer.insetBy(dx: -1, dy: -1).contains(pointInContainer) {
                return rowID
            }
        }
        return nil
    }

    private func updateScrollObservation() {
        let nextClipView = containerView?.enclosingScrollView?.contentView
        guard observedClipView !== nextClipView else { return }
        if let observer = clipBoundsObserver {
            NotificationCenter.default.removeObserver(observer)
            clipBoundsObserver = nil
        }
        observedClipView = nextClipView
        guard let nextClipView else { return }
        nextClipView.postsBoundsChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: nextClipView,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleReconcileCurrentPointer()
            }
        }
    }
}
