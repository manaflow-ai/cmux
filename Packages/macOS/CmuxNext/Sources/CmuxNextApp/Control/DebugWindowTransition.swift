import AppKit
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.window_transition` (DEBUG builds): what a window does while it
/// enters or leaves full screen, or moves to another Space
/// (scripts/cmux-next/fullscreen-transition.py).
///
/// `start` clears the trace and records, with ms offsets from the start:
/// the full-screen and Space notifications, every window resize (its size),
/// and every outermost window layout pass (`ShellWindow.layoutIfNeeded`,
/// with its main-thread duration). `stop` (or `read`) returns the trace
/// plus counter deltas: `LayoutRootView` layouts, terminal grid reports the
/// views made and terminal resizes sent to the daemon.
@MainActor
final class DebugWindowTransition {
    static let shared = DebugWindowTransition()
    private(set) var isActive = false
    private var start: CFTimeInterval = 0
    private var events: [JSONValue] = []
    private var layoutDurations: [Double] = []
    /// Each shell window's notices through its one ``WindowEvents``, and the Space change through the app's
    /// NSWorkspace ``AppEvents``; released by `end()`.
    private var subscriptions: [EventSubscription] = []
    private var baseRootLayouts: UInt64 = 0
    private var baseResizeSends: UInt64 = 0
    private var baseGridReports: UInt64 = 0
    private static let capacity = 20_000

    /// - Parameter workspaceEvents: The app's ``AppEvents`` on NSWorkspace's center (the Space change).
    func handle(_ params: [String: JSONValue], workspaceEvents: AppEvents) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start": begin(workspaceEvents)
        case "geometry": return geometry
        case "click_zoom":
            // The green button's own path (AppKit's zoom button action).
            guard let window = NSApp.orderedWindows.first(where: { $0 is ShellWindow }),
                  let button = window.standardWindowButton(.zoomButton) else { return ["error": "no zoom button"] }
            button.performClick(nil)
            return ["clicked": true]
        case "stop":
            let report = self.report
            end()
            return report
        default: break
        }
        return report
    }

    /// One outermost layout pass of a shell window took `seconds`.
    func noteLayoutPass(_ window: NSWindow, seconds: Double) {
        guard isActive, events.count < Self.capacity else { return }
        layoutDurations.append(seconds * 1_000)
        let band = (window.contentView as? WindowRootView)?.toolbarBand.frame
        events.append(["t": .number(now), "e": "layout", "ms": .number((seconds * 1_000 * 100).rounded() / 100),
                       "w": .number(window.frame.width), "h": .number(window.frame.height),
                       "fs": .bool(window.styleMask.contains(.fullScreen)),
                       "lights": rect(WindowTitlebar.trafficLightsFrame(in: window)), "band_x": .number(Double(band?.minX ?? -1))])
    }

    private var now: Double { ((CACurrentMediaTime() - start) * 1_000 * 10).rounded() / 10 }

    /// The window notices the trace records, by label.
    // raw-observer-allow: names each shell window's one WindowEvents subscribes to (recipe R-notif); no observer of its own
    private static let notices: [(Notification.Name, String)] = [(NSWindow.willEnterFullScreenNotification, "willEnter"), (NSWindow.didEnterFullScreenNotification, "didEnter"), (NSWindow.willExitFullScreenNotification, "willExit"), (NSWindow.didExitFullScreenNotification, "didExit"), (NSWindow.didResizeNotification, "resize"), (NSWindow.didChangeScreenNotification, "screen"), (NSWindow.didChangeOcclusionStateNotification, "occlusion")]

    private func begin(_ workspaceEvents: AppEvents) {
        end()
        events.removeAll()
        layoutDurations.removeAll()
        start = CACurrentMediaTime()
        baseRootLayouts = LayoutRootView.layoutPasses
        baseResizeSends = ResizeCoordinator.sent
        baseGridReports = TerminalSurfaceView.gridReports
        isActive = true
        // The shell windows open at the start; a trace follows one window through its transition.
        for window in NSApp.windows.compactMap({ $0 as? ShellWindow }) {
            let events = WindowEvents.of(window)
            for (name, label) in Self.notices {
                subscriptions.append(events.subscribe(name, owner: "DebugWindowTransition") { [weak self, weak window] in
                    guard let window else { return }
                    self?.record(label, window)
                })
            }
        }
        subscriptions.append(workspaceEvents.subscribe(NSWorkspace.activeSpaceDidChangeNotification, owner: "DebugWindowTransition") { [weak self] in
            self?.events.append(["t": .number(self?.now ?? 0), "e": "space"])
        })
    }

    private func record(_ label: String, _ window: NSWindow) {
        guard isActive, events.count < Self.capacity else { return }
        events.append(["t": .number(now), "e": .string(label), "w": .number(window.frame.width), "h": .number(window.frame.height),
                       "fs": .bool(window.styleMask.contains(.fullScreen))])
    }

    private func end() {
        subscriptions.removeAll()
        isActive = false
    }

    /// The top row of every shell window, in window coordinates: what moves
    /// when the traffic lights come and go.
    private var geometry: JSONValue {
        var out: [JSONValue] = []
        for window in NSApp.orderedWindows.compactMap({ $0 as? ShellWindow }) {
            let root = window.contentView as? WindowRootView
            out.append([
                "full_screen": .bool(window.styleMask.contains(.fullScreen)),
                "frame": rect(window.frame),
                "content": rect(window.contentView?.bounds),
                "content_layout": rect(window.contentLayoutRect),
                "safe_top": .number(Double(window.contentView?.safeAreaInsets.top ?? 0)),
                "lights": rect(WindowTitlebar.trafficLightsFrame(in: window)),
                "toolbar_band": shownRect(root?.toolbarBand),
                "sidebar": shownRect(root?.sidebar),
                "main_pane": shownRect(root?.contentHost),
            ])
        }
        return .array(out)
    }

    private var report: JSONValue {
        let sorted = layoutDurations.sorted()
        return [
            "active": .bool(isActive),
            "events": .array(events),
            "layout_passes": JSONValue(layoutDurations.count),
            "layout_total_ms": .number((layoutDurations.reduce(0, +) * 10).rounded() / 10),
            "layout_max_ms": .number(((sorted.last ?? 0) * 10).rounded() / 10),
            "root_layouts": JSONValue(Int(truncatingIfNeeded: LayoutRootView.layoutPasses &- baseRootLayouts)),
            "terminal_grid_reports": JSONValue(Int(truncatingIfNeeded: TerminalSurfaceView.gridReports &- baseGridReports)),
            "terminal_resizes_sent": JSONValue(Int(truncatingIfNeeded: ResizeCoordinator.sent &- baseResizeSends)),
        ]
    }
}
/// A shown view's frame in window coordinates, or null.
private func shownRect(_ view: NSView?) -> JSONValue {
    // visibility-walk-allow: the trace reports the geometry AppKit shows during a full-screen transition, its own view state
    guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return .null }
    return rect(view.convert(view.bounds, to: nil))
}

/// `[x, y, width, height]`, or null.
private func rect(_ r: CGRect?) -> JSONValue {
    guard let r else { return .null }
    return [.number(r.minX), .number(r.minY), .number(r.width), .number(r.height)]
}
#endif
