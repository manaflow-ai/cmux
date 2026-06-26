import AppKit

extension CanvasPagesRootView {
    func installPageScrollMonitor() {
        guard pageScrollMonitor == nil else { return }
        pageScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  let location = self.pageScrollLocation(for: event, in: window) else {
                return event
            }

            guard self.canRoutePageScroll(at: location) else {
                return event
            }

            guard self.handlePageScroll(event) else {
                return event
            }
            return nil
        }
    }

    func removePageScrollMonitor() {
        if let pageScrollMonitor {
            NSEvent.removeMonitor(pageScrollMonitor)
        }
        pageScrollMonitor = nil
    }

    private func pageScrollLocation(for event: NSEvent, in window: NSWindow) -> NSPoint? {
        if event.window === window || event.windowNumber == window.windowNumber {
            return convert(event.locationInWindow, from: nil)
        }

        if let eventWindow = event.window {
            guard eventWindowBelongsToRoot(eventWindow, root: window) else { return nil }
            return convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }

        if event.windowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: event.windowNumber),
           numberedWindow !== window {
            guard eventWindowBelongsToRoot(numberedWindow, root: window) else { return nil }
            return convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }

        // Portal-hosted content and synthesized scroll events can arrive
        // without the main window on the event. The physical cursor location
        // still tells us whether the gesture belongs to this Pages root.
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func eventWindowBelongsToRoot(_ candidate: NSWindow, root: NSWindow) -> Bool {
        var current: NSWindow? = candidate
        while let window = current {
            if window === root { return true }
            current = window.parent
        }
        return false
    }

    func canRoutePageScroll(at location: NSPoint) -> Bool {
        guard shouldRenderPreparedPages,
              bounds.contains(location) else {
            return false
        }
        return !paneTitleBarCanHandleScroll(at: location)
    }

    private func paneTitleBarCanHandleScroll(at location: NSPoint) -> Bool {
        var current = hitTest(location)
        while let view = current {
            if let paneView = view as? CanvasPaneView {
                return paneView.canHandleTitleBarScroll(at: location, in: self)
            }
            current = view.superview
        }
        return false
    }

    private func handlePageScroll(_ event: NSEvent) -> Bool {
        guard pageObjects.count > 1 else { return false }

        let deltaX = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard CanvasPagesScrollRouting().shouldRouteToNativePages(
            deltaX: deltaX,
            deltaY: deltaY,
            isShiftPressed: event.modifierFlags.contains(.shift)
        ) else {
            return false
        }

        pageController.view.scrollWheel(with: event)
        return true
    }
}
