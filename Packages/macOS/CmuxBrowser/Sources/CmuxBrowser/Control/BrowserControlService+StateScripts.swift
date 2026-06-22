import Foundation

/// JavaScript builders for the page-world `browser` telemetry and session-state
/// control commands (`browser.console.list`, `browser.console.clear`,
/// `browser.errors.list`, `browser.state.save`, `browser.state.load`).
///
/// Every string returned here is byte-identical to the script the corresponding
/// `v2BrowserConsoleList` / `v2BrowserErrorsList` / `v2BrowserStateSave` /
/// `v2BrowserStateLoad` method previously assembled inline in `TerminalController`;
/// only the assembly moved. The owning `@MainActor` controller keeps the WebKit
/// evaluation seam, the per-surface frame-selector / telemetry-hook state, the
/// `WKHTTPCookieStore` reads/writes, and the JSON state-file I/O, so the wire
/// output is unchanged.
extension BrowserControlService {
    /// Builds the page-world script that reads (and optionally clears) the
    /// `window.__cmuxConsoleLog` telemetry ring for `browser.console.list` /
    /// `browser.console.clear`.
    ///
    /// Returns `{ ok: true, items }` with a shallow copy of the ring; when
    /// `clear` is `true` the ring is reset to `[]` after the copy. Byte-identical
    /// to the script previously inlined in `v2BrowserConsoleList`.
    /// - Parameter clear: whether to clear the ring after reading it.
    /// - Returns: a self-invoking JavaScript expression.
    public func consoleLogReadScript(clear: Bool) -> String {
        let clearLiteral = clear ? "true" : "false"
        return """
        (() => {
          const items = Array.isArray(window.__cmuxConsoleLog) ? window.__cmuxConsoleLog.slice() : [];
          if (\(clearLiteral)) {
            window.__cmuxConsoleLog = [];
          }
          return { ok: true, items };
        })()
        """
    }

    /// Builds the page-world script that reads (and optionally clears) the
    /// `window.__cmuxErrorLog` telemetry ring for `browser.errors.list`.
    ///
    /// Returns `{ ok: true, items }` with a shallow copy of the ring; when
    /// `clear` is `true` the ring is reset to `[]` after the copy. Byte-identical
    /// to the script previously inlined in `v2BrowserErrorsList`.
    /// - Parameter clear: whether to clear the ring after reading it.
    /// - Returns: a self-invoking JavaScript expression.
    public func errorLogReadScript(clear: Bool) -> String {
        let clearLiteral = clear ? "true" : "false"
        return """
        (() => {
          const items = Array.isArray(window.__cmuxErrorLog) ? window.__cmuxErrorLog.slice() : [];
          if (\(clearLiteral)) {
            window.__cmuxErrorLog = [];
          }
          return { ok: true, items };
        })()
        """
    }

    /// Builds the page-world script that snapshots both `window.localStorage` and
    /// `window.sessionStorage` into a `{ local, session }` object for
    /// `browser.state.save`.
    ///
    /// Each area is read key-by-key into a plain object; a missing area yields an
    /// empty object. Byte-identical to the script previously inlined in
    /// `v2BrowserStateSave`.
    /// - Returns: a self-invoking JavaScript expression.
    public func storageSnapshotScript() -> String {
        """
        (() => {
          const readStorage = (st) => {
            const out = {};
            if (!st) return out;
            for (let i = 0; i < st.length; i++) {
              const k = st.key(i);
              out[k] = st.getItem(k);
            }
            return out;
          };
          return {
            local: readStorage(window.localStorage),
            session: readStorage(window.sessionStorage)
          };
        })()
        """
    }

    /// Builds the page-world script that restores a previously saved
    /// `{ local, session }` storage snapshot into `window.localStorage` /
    /// `window.sessionStorage` for `browser.state.load`.
    ///
    /// Each area is cleared and repopulated from its payload entries, coercing
    /// every value to a string (`null` written as the empty string). Byte-identical
    /// to the script previously inlined in `v2BrowserStateLoad`.
    /// - Parameter storageLiteral: the already-encoded JavaScript object literal
    ///   for the saved storage payload (the caller renders the saved snapshot via
    ///   ``jsonLiteral(_:)`` so the controller keeps ownership of the encoding seam).
    /// - Returns: a self-invoking JavaScript expression.
    public func storageRestoreScript(storageLiteral: String) -> String {
        """
        (() => {
          const payload = \(storageLiteral);
          const apply = (st, data) => {
            if (!st || !data || typeof data !== 'object') return;
            st.clear();
            for (const [k, v] of Object.entries(data)) {
              st.setItem(String(k), v == null ? '' : String(v));
            }
          };
          apply(window.localStorage, payload.local);
          apply(window.sessionStorage, payload.session);
          return true;
        })()
        """
    }
}
