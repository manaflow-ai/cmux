#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextSettings
import CmuxNextWakeups
import WebKit

/// DEBUG ONLY. `debug.frames {action: "start", resize_trace: true}`: one
/// sample per display frame of the active window while it records, so a
/// live-resize bench sees whether each surface follows the window's size in
/// the same frame (cx-sqj3h). A sample holds the window's content width, the
/// sidebar's, and per shown pane its host, tab strip and content widths,
/// plus what each content committed:
/// - a terminal: the grid it renders and the grid its view fits;
/// - an agent page: the web view's width and zoom, and the page's own
///   `innerWidth` with the number of animations on its thread, from a
///   script sent at that frame (`page` holds the frame it was sent at and the
///   frame its answer came back);
/// - a Chromium page: its child windows' widths.
/// `debug.frames {action: "stop"}` returns the samples as `resize_trace`.
@MainActor
final class DebugResizeTrace {
    private let services: AppServices
    private lazy var client = FrameClient(owner: "debug.resize_trace", isAnimation: false, on: .app) { [weak self] _ in
        self?.sample()
        return self != nil
    }
    private var start: CFTimeInterval = 0
    private var samples: [JSONValue] = []
    private var pages: [JSONValue] = []
    private var inFlight: Set<ObjectIdentifier> = []
    static let capacity = 20_000

    init(services: AppServices) {
        self.services = services
    }

    func begin() {
        samples.removeAll(keepingCapacity: true)
        pages.removeAll(keepingCapacity: true)
        start = CACurrentMediaTime()
        client.activate()
    }

    func end() -> JSONValue {
        client.deactivate()
        return .object(["samples": .array(samples), "pages": .array(pages)])
    }

    private func sample() {
        guard samples.count < Self.capacity, let controller = services.windows.active, let window = controller.window else { return }
        let frame = samples.count
        var panes: [JSONValue] = []
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pane.view.window === window && !pane.view.isHiddenOrHasHiddenAncestor {
            var fields: [String: JSONValue] = [
                "pane": .string(pane.paneKey),
                "host_w": .number(pane.view.bounds.width),
                "strip_w": .number(pane.view.stripView.frame.width),
            ]
            switch pane.currentContent {
            case .terminal(let entry)?:
                let diagnostics = entry.session.diagnostics
                fields["kind"] = .string("terminal")
                fields["content_w"] = .number(diagnostics.viewSize.width)
                fields["cols"] = .number(Double(diagnostics.grid?.columns ?? 0))
                fields["fit_cols"] = .number(Double(diagnostics.fitGrid?.columns ?? 0))
            case .agent(let view)?:
                fields["kind"] = .string("agent")
                fields["content_w"] = .number(view.webView.frame.width)
                fields["zoom"] = .number(view.webView.pageZoom)
                ping(view.webView, pane: pane.paneKey, frame: frame)
            case .browser(let entry)?:
                fields["kind"] = .string("browser")
                fields["content_w"] = .number(entry.tab.contentView.bounds.width)
                if entry.tab.presentation == .childWindow {
                    fields["page_windows_w"] = .array(WindowOverlayLayer.contentChildWindows(of: window).map { .number($0.frame.width) })
                }
            default:
                fields["kind"] = .string("other")
            }
            panes.append(.object(fields))
        }
        samples.append(.object([
            "frame": .number(Double(frame)),
            "t_ms": .number(((CACurrentMediaTime() - start) * 1_000).rounded()),
            "live": .bool(window.inLiveResize),
            "window_w": .number(Double(window.contentView?.bounds.width ?? 0)),
            "sidebar_w": .number(controller.root.sidebar.frame.width),
            "panes": .array(panes),
        ]))
    }

    /// The page's own width and its thread's running animations, asked at
    /// `frame`; one script per page in flight.
    private func ping(_ webView: WKWebView, pane: String, frame: Int) {
        let key = ObjectIdentifier(webView)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let script = "[innerWidth, (document.querySelector('.acpmux-thread')?.getAnimations?.() ?? []).length]"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated { // main-proof: WKWebView completions run on the main thread
                guard let self else { return }
                self.inFlight.remove(key)
                let values = result as? [NSNumber] ?? []
                self.pages.append(.object([
                    "pane": .string(pane),
                    "sent": .number(Double(frame)),
                    "answered": .number(Double(self.samples.count)),
                    "inner_w": .number(values.first?.doubleValue ?? -1),
                    "animations": .number(values.count > 1 ? values[1].doubleValue : -1),
                ]))
            }
        }
    }
}
#endif
