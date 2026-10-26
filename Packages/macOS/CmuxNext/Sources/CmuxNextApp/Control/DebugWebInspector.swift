#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBridge
import CmuxNextSettings
import CmuxNextBrowser
import CmuxNextCompat

/// `debug.webkit_inspector` (DEBUG builds): the WebKit page view of each
/// shown WebKit tab, its superview's subviews (WebKit puts an attached Web
/// Inspector there) and how often each of them changed frame since
/// `{"action": "start"}`. Two owners fighting over a frame show as counts
/// that keep growing while nothing changes.
@MainActor
enum DebugWebInspector {
    private static var counts: [ObjectIdentifier: Int] = [:]
    private static var observers: [MainActorObservation] = []
    private static var started: Double = 0

    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let views = pages(services)
        if params["action"]?.stringValue == "start" {
            observers.removeAll()
            counts.removeAll()
            started = ProcessInfo.processInfo.systemUptime
            // AppKit-only: WebKit owns these views and their layout (no hook of ours to push from), and this
            // counter is the probe itself, in DEBUG and bench builds only (allowed in render-done-checks.py).
            for view in views.flatMap({ [$0.page] + ($0.page.superview?.subviews ?? []) }) {
                view.postsFrameChangedNotifications = true
                let id = ObjectIdentifier(view)
                // raw-observer-allow: counts frame changes of WebKit's own views, whose layout has no hook of ours (the probe itself)
                observers.append(MainActorObservation(NSView.frameDidChangeNotification, object: view) { counts[id, default: 0] += 1 })
            }
        }
        return .object([
            "seconds": .number(ProcessInfo.processInfo.systemUptime - started),
            "tabs": .array(views.map { entry in
                let siblings = entry.page.superview?.subviews ?? [entry.page]
                return .object([
                    "pane": .string(entry.pane),
                    "container": .string(entry.page.superview.map { String(describing: type(of: $0)) } ?? "nil"),
                    "views": .array(siblings.map { view in
                        .object([
                            "class": .string(String(describing: type(of: view))), "page": .bool(view === entry.page),
                            "frame": .array([view.frame.minX, view.frame.minY, view.frame.width, view.frame.height].map { .number(Double($0)) }),
                            "hidden": .bool(view.isHidden), "frame_changes": .number(Double(counts[ObjectIdentifier(view)] ?? 0)),
                        ])
                    }),
                ])
            }),
        ])
    }

    private static func pages(_ services: AppServices) -> [(pane: String, page: NSView)] {
        services.windows.controllers.flatMap { controller in
            (controller.content?.panes.values.map { $0 } ?? []).compactMap { pane -> (String, NSView)? in
                guard case .browser(let entry)? = pane.currentContent, let tab = entry.tab as? WebKitTab else { return nil }
                return (pane.paneKey, tab.webView)
            }
        }
    }
}
#endif
