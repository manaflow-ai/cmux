import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing
import WebKit

/// R96 mechanism choice: time from "show this dialog" until it is laid out,
/// for the native dialog and for the same dialog as a web overlay (cold:
/// a new web view; warm: a loaded web view that builds the DOM). Runs only
/// with CMUX_DIALOG_BENCH=1 (on cmux-lawrence-2), prints medians and p95.
/// Windows are never ordered on screen; the web numbers stop at layout
/// (`offsetHeight`), which is earlier than a painted frame, so they favor
/// the web path.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_DIALOG_BENCH"] == "1"))
struct CmuxDialogLatencyBench {
    static let runs = 40
    static let html = """
    <html><body style="margin:0;font:13px -apple-system"><div id="host"></div><script>
    function show() {
      const d = document.createElement('div'); d.setAttribute('role','alertdialog');
      d.innerHTML = '<b>Close Workspace “api”?</b><p>vim and npm are still running.</p><input value="zsh"><button>Cancel</button><button>Close</button>';
      document.getElementById('host').replaceChildren(d); return d.offsetHeight;
    }
    </script></body></html>
    """

    @MainActor final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?.resume()
            done = nil
        }
    }

    static func report(_ name: String, _ samples: [Duration]) -> String {
        let ms = samples.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }.sorted()
        let median = ms[ms.count / 2]
        let p95 = ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))]
        let line = String(format: "BENCH %@ median=%.2fms p95=%.2fms n=%d", name, median, p95, ms.count)
        print(line)
        return line
    }

    @Test func nativeVersusWeb() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let center = CmuxDialogCenter()
        let spec = CmuxDialogSpec(title: "Close Workspace “api”?", lines: ["vim and npm are still running."],
                                  fields: [.text("name", initial: "zsh")],
                                  buttons: [.cancel(), CmuxDialogButton(id: "close", title: "Close", role: .destructive)])
        let clock = ContinuousClock()

        var native: [Duration] = []
        for _ in 0..<Self.runs {
            let start = clock.now
            let id = center.present(spec, in: .window(window)) { _ in }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            native.append(clock.now - start)
            center.dismiss(id)
        }

        var cold: [Duration] = []
        for _ in 0..<(Self.runs / 4) {
            let start = clock.now
            let web = WKWebView(frame: window.contentView?.bounds ?? .zero)
            window.contentView?.addSubview(web)
            let loader = Loader()
            web.navigationDelegate = loader
            await withCheckedContinuation { continuation in
                loader.done = continuation
                web.loadHTMLString(Self.html, baseURL: nil)
            }
            _ = try await web.evaluateJavaScript("show()")
            cold.append(clock.now - start)
            web.removeFromSuperview()
        }

        let web = WKWebView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(web)
        let loader = Loader()
        web.navigationDelegate = loader
        await withCheckedContinuation { continuation in
            loader.done = continuation
            web.loadHTMLString(Self.html, baseURL: nil)
        }
        var warm: [Duration] = []
        for _ in 0..<Self.runs {
            let start = clock.now
            _ = try await web.evaluateJavaScript("show()")
            warm.append(clock.now - start)
        }

        let lines = [Self.report("native", native), Self.report("web-cold", cold), Self.report("web-warm", warm)]
        if let path = ProcessInfo.processInfo.environment["NX_ARTIFACTS"] {
            try lines.joined(separator: "\n").write(toFile: path + "/dialog-latency.txt", atomically: true, encoding: .utf8)
        }
    }
}
