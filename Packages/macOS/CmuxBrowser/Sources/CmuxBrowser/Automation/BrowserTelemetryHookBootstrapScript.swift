import Foundation

/// JavaScript bootstrap snippets that install cmux's browser telemetry hooks into a page.
///
/// Each script is an idempotent immediately-invoked function expression injected at document
/// start (main frame only) so console/error/dialog telemetry stays active across navigations.
/// The console/error variant overrides `console.*`, captures `error`/`unhandledrejection`
/// events into capped `window.__cmuxConsoleLog`/`window.__cmuxErrorLog` ring buffers, and
/// guards against double-install via `window.__cmuxHooksInstalled`. The dialog variant
/// overrides `window.alert`/`confirm`/`prompt`, queues their invocations into a capped
/// `window.__cmuxDialogQueue`, returns the caller-configured `window.__cmuxDialogDefaults`,
/// and guards via `window.__cmuxDialogHooksInstalled`. Both evaluate to `true`.
public struct BrowserTelemetryHookBootstrapScript: Sendable, Equatable {
    /// JS source that installs the console/error telemetry hooks.
    public static let consoleAndErrorSource = """
    (() => {
      if (window.__cmuxHooksInstalled) return true;
      window.__cmuxHooksInstalled = true;

      window.__cmuxConsoleLog = window.__cmuxConsoleLog || [];
      const __pushConsole = (level, args) => {
        try {
          const text = Array.from(args || []).map((x) => {
            if (typeof x === 'string') return x;
            try { return JSON.stringify(x); } catch (_) { return String(x); }
          }).join(' ');
          window.__cmuxConsoleLog.push({ level, text, timestamp_ms: Date.now() });
          if (window.__cmuxConsoleLog.length > 512) {
            window.__cmuxConsoleLog.splice(0, window.__cmuxConsoleLog.length - 512);
          }
        } catch (_) {}
      };

      const methods = ['log', 'info', 'warn', 'error', 'debug'];
      for (const m of methods) {
        const orig = (window.console && window.console[m]) ? window.console[m].bind(window.console) : null;
        window.console[m] = function(...args) {
          __pushConsole(m, args);
          if (orig) return orig(...args);
        };
      }

      window.__cmuxErrorLog = window.__cmuxErrorLog || [];
      window.addEventListener('error', (ev) => {
        try {
          const message = String((ev && ev.message) || '');
          const source = String((ev && ev.filename) || '');
          const line = Number((ev && ev.lineno) || 0);
          const col = Number((ev && ev.colno) || 0);
          window.__cmuxErrorLog.push({ message, source, line, column: col, timestamp_ms: Date.now() });
          if (window.__cmuxErrorLog.length > 512) {
            window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
          }
        } catch (_) {}
      });
      window.addEventListener('unhandledrejection', (ev) => {
        try {
          const reason = ev && ev.reason;
          const message = typeof reason === 'string' ? reason : (reason && reason.message ? String(reason.message) : String(reason));
          window.__cmuxErrorLog.push({ message, source: 'unhandledrejection', line: 0, column: 0, timestamp_ms: Date.now() });
          if (window.__cmuxErrorLog.length > 512) {
            window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
          }
        } catch (_) {}
      });

      return true;
    })()
    """

    /// JS source that installs the dialog (`alert`/`confirm`/`prompt`) telemetry hooks.
    public static let dialogSource = """
    (() => {
      if (window.__cmuxDialogHooksInstalled) return true;
      window.__cmuxDialogHooksInstalled = true;

      window.__cmuxDialogQueue = window.__cmuxDialogQueue || [];
      window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
      const __pushDialog = (type, message, defaultText) => {
        window.__cmuxDialogQueue.push({
          type,
          message: String(message || ''),
          default_text: defaultText == null ? null : String(defaultText),
          timestamp_ms: Date.now()
        });
        if (window.__cmuxDialogQueue.length > 128) {
          window.__cmuxDialogQueue.splice(0, window.__cmuxDialogQueue.length - 128);
        }
      };

      window.alert = function(message) {
        __pushDialog('alert', message, null);
      };
      window.confirm = function(message) {
        __pushDialog('confirm', message, null);
        return !!window.__cmuxDialogDefaults.confirm;
      };
      window.prompt = function(message, defaultValue) {
        __pushDialog('prompt', message, defaultValue == null ? null : defaultValue);
        const v = window.__cmuxDialogDefaults.prompt;
        if (v === null || v === undefined) {
          return defaultValue == null ? '' : String(defaultValue);
        }
        return String(v);
      };

      return true;
    })()
    """
}
