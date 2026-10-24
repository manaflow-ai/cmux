public import WebKit

/// Catches an app page's `console.error`, `console.warn`, uncaught errors and unhandled promise
/// rejections and records each, redacted, when it happens (source `page:<page>`), through the
/// one reporting path (``ErrorReporter``): into the recorder the page was made with (the app's
/// ``ErrorJournal``), so a crash loses none and no log harvest is needed for them, and into the
/// unified log under ``subsystem`` with the page name as category, for Console.app.
/// ``OSLogErrorSource`` leaves that subsystem out, so nothing counts twice. Nothing flows back
/// into the page; the page script drops all but 20 reports a second.
///
/// ```swift
/// ConsoleErrorCapture(page: "settings", recorder: journal).install(in: configuration.userContentController)
/// ```
@MainActor
public struct ConsoleErrorCapture {
    /// The unified-log subsystem of page console reports.
    public nonisolated static let subsystem = "com.cmuxterm.page-console"
    /// The script message handler name the page posts to.
    public nonisolated static let handlerName = "cmuxConsoleError"

    /// The page's name: the log category and the journal source `page:<page>`.
    public let page: String
    /// Logs and records each report (``ErrorReporter``'s one path).
    private let reporter: ErrorReporter

    /// Makes a capture for one page.
    /// - Parameters:
    ///   - page: The page's name (log category, journal source `page:<page>`).
    ///   - recorder: Where each report goes when it happens: the app's journal (its composition
    ///     root makes the one journal and passes it to every page); a test's recorder.
    public init(page: String, recorder: any ErrorRecording) {
        self.page = page
        reporter = ErrorReporter(subsystem: Self.subsystem, category: page, source: "page:\(page)", recorder: recorder)
    }

    /// The document-start script that reports console errors to ``handlerName``.
    public nonisolated static let script = """
    (() => {
      if (window.__cmuxConsoleErrorCapture) return;
      window.__cmuxConsoleErrorCapture = true;
      let windowStart = 0, budget = 0;
      const allow = () => {
        const now = Date.now();
        if (now - windowStart > 1000) { windowStart = now; budget = 20; }
        return budget-- > 0;
      };
      const text = (value) => {
        if (value instanceof Error) return value.message;
        if (typeof value === "string") return value;
        try { return JSON.stringify(value); } catch (_) { return String(value); }
      };
      const post = (level, message, stack) => {
        if (!allow()) return;
        try {
          window.webkit.messageHandlers.\(handlerName).postMessage({
            level, message: String(message).slice(0, 2000), stack: String(stack || "").slice(0, 2000),
            path: location.pathname + location.hash.split("?")[0],
          });
        } catch (_) {}
      };
      for (const level of ["error", "warn"]) {
        const original = console[level];
        console[level] = function (...args) {
          const error = args.find((arg) => arg instanceof Error);
          post(level, args.map(text).join(" "), error && error.stack);
          return original.apply(this, args);
        };
      }
      addEventListener("error", (event) => {
        if (event.error === undefined && event.target && event.target !== window) {
          const target = event.target;
          post("error", "resource failed: " + (target.src || target.href || target.tagName), "");
          return;
        }
        post("error", event.message || "uncaught error",
             (event.error && event.error.stack) || `at ${event.filename}:${event.lineno}`);
      }, true);
      addEventListener("unhandledrejection", (event) => {
        const reason = event.reason;
        post("error", "unhandled rejection: " + text(reason), reason && reason.stack);
      });
    })();
    """

    /// Adds the script and its message handler to `controller`.
    public func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.add(ConsoleErrorReceiver(capture: self), contentWorld: .page, name: Self.handlerName)
    }

    /// Records one message of ``script``: WebKit's handler calls it, and so does a Chromium page's
    /// binding, which reaches the host another way.
    ///
    /// - Parameter body: The posted object (`level`, `message`, `stack`).
    /// - Returns: The journal's record of it (tests await it); nil for a body that is not a report.
    @discardableResult
    public func record(_ body: Any) -> Task<Void, Never>? {
        guard let body = body as? [String: Any] else { return nil }
        return report(level: body["level"] as? String ?? "error", message: body["message"] as? String ?? "",
                      stack: body["stack"] as? String ?? "")
    }

    /// Logs one report and records it now. The journal gets the same event the log harvest made
    /// of the log line (``OSLogErrorSource/event(subsystem:category:isFault:message:date:)``), so
    /// its fingerprint is the one earlier launches kept.
    private func report(level: String, message: String, stack: String) -> Task<Void, Never> {
        let text = Self.logText(level: level, message: message, stack: stack)
        let event = OSLogErrorSource.event(subsystem: Self.subsystem, category: page, isFault: false, message: text,
                                           date: Date())
        return reporter.report(event, logText: text)
    }

    /// The log line for one report: `[warn] ` for warnings, then the message, then the top
    /// stack frame as an `at …` line.
    public nonisolated static func logText(level: String, message: String, stack: String) -> String {
        let redactor = ErrorRedactor()
        let prefix = level == "warn" ? "[warn] " : ""
        let firstLine = message.split(separator: "\n").first.map(String.init) ?? message
        var text = prefix + redactor.redact(firstLine).utf8Prefix(1024)
        if let frame = topFrame(stack) { text += "\n    at " + redactor.redact(frame).utf8Prefix(256) }
        return text
    }

    /// The first stack line that names code (V8 `at f (url:1:2)` or JSC `f@url:1:2`).
    nonisolated static func topFrame(_ stack: String) -> String? {
        for raw in stack.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("at ") { return String(line.dropFirst(3)) }
            if line.contains("@"), line.contains(":") { return line }
        }
        return nil
    }
}

/// Receives the page's reports and hands them to its capture; main-frame reports only.
@MainActor
private final class ConsoleErrorReceiver: NSObject, WKScriptMessageHandler {
    let capture: ConsoleErrorCapture

    init(capture: ConsoleErrorCapture) {
        self.capture = capture
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        capture.record(message.body)
    }
}
