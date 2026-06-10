import AppKit
import Bonsplit
import SwiftUI


// MARK: - Titlebar double-click monitor view
private func titlebarDoubleClickMonitorShouldDeferToRegisteredControl(
    window: NSWindow,
    locationInWindow: NSPoint
) -> Bool {
    isMinimalModeTitlebarControlHit(window: window, locationInWindow: locationInWindow)
}

/// Local monitor that guarantees double-clicks in custom titlebar surfaces trigger
/// the standard macOS titlebar action even when the visible strip is hosted by
/// higher-level SwiftUI/AppKit container views.
struct TitlebarDoubleClickMonitorView: NSViewRepresentable {
    var doubleClickBehavior: TitlebarDoubleClickBehavior = .standardAction

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var doubleClickBehavior: TitlebarDoubleClickBehavior = .standardAction
        var lastClick: MinimalModeTitlebarClickRecord?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.view = view
        context.coordinator.doubleClickBehavior = doubleClickBehavior

        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak coordinator] event in
            guard let coordinator, let view = coordinator.view, let window = view.window else { return event }
            guard event.window === window else { return event }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else {
                coordinator.lastClick = nil
                return event
            }
            guard !titlebarDoubleClickMonitorShouldDeferToRegisteredControl(
                window: window,
                locationInWindow: event.locationInWindow
            ) else {
                coordinator.lastClick = nil
                return event
            }
            let isDoubleClick = minimalModeTitlebarClickFormsDoubleClick(
                clickCount: event.clickCount,
                timestamp: event.timestamp,
                locationInWindow: event.locationInWindow,
                windowNumber: window.windowNumber,
                previous: coordinator.lastClick,
                doubleClickInterval: NSEvent.doubleClickInterval,
                doubleClickIntervalTolerance: minimalModeTitlebarSyntheticDoubleClickTolerance
            )
            guard isDoubleClick else {
                coordinator.lastClick = MinimalModeTitlebarClickRecord(
                    windowNumber: window.windowNumber,
                    timestamp: event.timestamp,
                    locationInWindow: event.locationInWindow
                )
                return event
            }
            coordinator.lastClick = nil

            let result = handleTitlebarDoubleClick(
                window: window,
                behavior: coordinator.doubleClickBehavior
            )
            #if DEBUG
            cmuxDebugLog("titlebar.monitor.doubleClick result=\(String(describing: result))")
            #endif
            return result.consumesEvent ? nil : event
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.doubleClickBehavior = doubleClickBehavior
    }
}

