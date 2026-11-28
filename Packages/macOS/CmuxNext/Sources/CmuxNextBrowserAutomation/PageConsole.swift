import Foundation
import WebKit

/// A driven tab's console calls and uncaught errors, from every frame, as
/// the driver's `console` and `pageerror` events (the CDP driver's
/// `Runtime.consoleAPICalled` and `Runtime.exceptionThrown`).
///
/// WebKit has no public console delegate, so a page-world script at document
/// start wraps the console methods and listens for `error` and
/// `unhandledrejection`, and posts each to a page-world message handler. The
/// page can see the wrappers and post forged messages; console text is the
/// page's own output either way.
@MainActor
enum PageConsole {
    static let handler = "cmuxConsole"

    static let source = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handler);
      if (!handler) return;
      const post = (message) => { try { handler.postMessage(message); } catch (e) {} };
      const text = (value) => {
        if (typeof value === "string") return value;
        if (value === null || (typeof value !== "object" && typeof value !== "function")) return String(value);
        if (value instanceof Error) return value.stack ? `${value.name}: ${value.message}\\n${value.stack}` : String(value);
        if (Array.isArray(value)) return `Array(${value.length})`;
        if (typeof value === "function") return String(value);
        const name = value.constructor && value.constructor.name;
        return name || "Object";
      };
      const types = { log: "log", info: "info", warn: "warning", error: "error", debug: "debug", trace: "trace", dir: "dir", table: "table" };
      for (const [method, type] of Object.entries(types)) {
        const original = console[method];
        if (typeof original !== "function") continue;
        console[method] = function (...args) {
          post({ kind: "console", type, text: args.map(text).join(" ") });
          return original.apply(this, args);
        };
      }
      const failure = (error, fallback) => {
        if (error instanceof Error) return { message: error.message, stack: `${error.name}: ${error.message}\\n${error.stack || ""}`.trimEnd() };
        const message = error === undefined ? fallback : text(error);
        return { message, stack: message };
      };
      window.addEventListener("error", (event) => {
        if (event.target !== window) return;
        post({ kind: "pageerror", ...failure(event.error, event.message) });
      });
      window.addEventListener("unhandledrejection", (event) => post({ kind: "pageerror", ...failure(event.reason, "Unhandled rejection") }));
    })();
    """

    /// The driver event for a handler message: `console {type, text}` or
    /// `pageerror {message, stack}`.
    static func event(_ body: Any) -> (name: String, payload: [String: DriverJSON])? {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return nil }
        switch kind {
        case "console":
            guard let type = body["type"] as? String, let text = body["text"] as? String else { return nil }
            return ("console", ["type": .string(type), "text": .string(text)])
        case "pageerror":
            guard let message = body["message"] as? String else { return nil }
            return ("pageerror", ["message": .string(message), "stack": .string(body["stack"] as? String ?? message)])
        default:
            return nil
        }
    }
}
