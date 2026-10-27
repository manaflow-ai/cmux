public import WebKit
import OSLog

/// Catches an app page's `console.error`, `console.warn`, uncaught errors and unhandled promise
/// rejections and writes them, redacted, to the unified log under ``subsystem`` with the page
/// name as category, where ``OSLogErrorSource`` harvests them into the journal. Nothing flows
/// back into the page; the page script drops all but 20 reports a second.
///
/// ```swift
/// ConsoleErrorCapture(page: "settings").install(in: configuration.userContentController) { badMessages += 1 }
/// ```
@MainActor
public struct ConsoleErrorCapture {
    /// The unified-log subsystem of page console reports.
    public nonisolated static let subsystem = "com.cmuxterm.page-console"
    /// The script message handler name the page posts to.
    public nonisolated static let handlerName = "cmuxConsoleError"

    /// The page's name: the log category and the journal source `page:<page>`.
    public let page: String

    /// Makes a capture for one page.
    public init(page: String) {
        self.page = page
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
    ///
    /// - Parameter onBadMessage: Called for each main-frame message ``report(_:)`` drops (the page's own
    ///   script can post anything to the handler), so the page counts it with its other bad messages.
    public func install(in controller: WKUserContentController, onBadMessage: @escaping @MainActor () -> Void) {
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.add(ConsoleErrorReceiver(page: page, onBadMessage: onBadMessage), contentWorld: .page,
                       name: Self.handlerName)
    }

    /// Logs one message of ``script`` that reached the host another way than WebKit's handler (a
    /// Chromium page's binding): the same redacted line the WebKit receiver logs.
    ///
    /// - Parameter body: The posted object (`level`, `message`, `stack`).
    /// - Returns: False for a body ``report(_:)`` drops; the caller counts it.
    public func record(_ body: Any) -> Bool {
        guard let report = Self.report(body) else { return false }
        // Redacted, so public: the journal must read the text back.
        Logger(subsystem: Self.subsystem, category: page).error("\(report.logText, privacy: .public)")
        return true
    }

    /// One posted report; a field the page left out is empty.
    public nonisolated struct Report: Equatable, Sendable {
        public var level = ""
        public var message = ""
        public var stack = ""

        /// The redacted log line (``ConsoleErrorCapture/logText(level:message:stack:)``); no level is `error`.
        public var logText: String {
            ConsoleErrorCapture.logText(level: level.isEmpty ? "error" : level, message: message, stack: stack)
        }
    }

    /// The report in a posted body, read key by key from the dictionary the engine hands over (as
    /// `JSONValue(foundation:)` reads one; this target links system frameworks only). Nil for a body that is
    /// no dictionary of string keys, or whose `level`, `message` or `stack` is no string; other members are
    /// never read. Never a `[String: Any]` cast: it traps on two keys that are distinct `NSString`s but equal
    /// Swift strings (`{"\u{E9}": 1, "e\u{301}": 2}`), which a page can post.
    public nonisolated static func report(_ body: Any) -> Report? {
        guard let dictionary = body as? NSDictionary else { return nil }
        var report = Report()
        for (key, value) in dictionary {
            guard let key = key as? String else { return nil }
            guard ["level", "message", "stack"].contains(key) else { continue }
            guard let text = value as? String else { return nil }
            switch key {
            case "level": report.level = text
            case "message": report.message = text
            default: report.stack = text
            }
        }
        return report
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

/// Receives the page's reports and logs them; main-frame reports only.
@MainActor
private final class ConsoleErrorReceiver: NSObject, WKScriptMessageHandler {
    let logger: Logger
    let onBadMessage: @MainActor () -> Void

    init(page: String, onBadMessage: @escaping @MainActor () -> Void) {
        logger = Logger(subsystem: ConsoleErrorCapture.subsystem, category: page)
        self.onBadMessage = onBadMessage
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        guard let report = ConsoleErrorCapture.report(message.body) else {
            onBadMessage()
            return
        }
        // Redacted, so public: the journal must read the text back.
        logger.error("\(report.logText, privacy: .public)")
    }
}
