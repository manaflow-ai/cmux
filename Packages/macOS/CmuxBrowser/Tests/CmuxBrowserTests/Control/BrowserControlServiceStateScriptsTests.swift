import Foundation
import Testing
@testable import CmuxBrowser

/// Exact-script tests for the page-world telemetry + session-state builders.
/// The browser RPC wire format is frozen, so each test asserts the full emitted
/// script (not fragments) against the string the `TerminalController` witnesses
/// previously assembled inline, catching any drift in the page-world JS.
@Suite("BrowserControlService state scripts")
struct BrowserControlServiceStateScriptsTests {
    let service = BrowserControlService()

    @Test("consoleLogReadScript emits the exact frozen wire script, clearing")
    func consoleLogReadScriptClear() {
        let expected = """
        (() => {
          const items = Array.isArray(window.__cmuxConsoleLog) ? window.__cmuxConsoleLog.slice() : [];
          if (true) {
            window.__cmuxConsoleLog = [];
          }
          return { ok: true, items };
        })()
        """
        #expect(service.consoleLogReadScript(clear: true) == expected)
    }

    @Test("consoleLogReadScript emits the exact frozen wire script, non-clearing")
    func consoleLogReadScriptNoClear() {
        let expected = """
        (() => {
          const items = Array.isArray(window.__cmuxConsoleLog) ? window.__cmuxConsoleLog.slice() : [];
          if (false) {
            window.__cmuxConsoleLog = [];
          }
          return { ok: true, items };
        })()
        """
        #expect(service.consoleLogReadScript(clear: false) == expected)
    }

    @Test("errorLogReadScript emits the exact frozen wire script, clearing")
    func errorLogReadScriptClear() {
        let expected = """
        (() => {
          const items = Array.isArray(window.__cmuxErrorLog) ? window.__cmuxErrorLog.slice() : [];
          if (true) {
            window.__cmuxErrorLog = [];
          }
          return { ok: true, items };
        })()
        """
        #expect(service.errorLogReadScript(clear: true) == expected)
    }

    @Test("errorLogReadScript emits the exact frozen wire script, non-clearing")
    func errorLogReadScriptNoClear() {
        let expected = """
        (() => {
          const items = Array.isArray(window.__cmuxErrorLog) ? window.__cmuxErrorLog.slice() : [];
          if (false) {
            window.__cmuxErrorLog = [];
          }
          return { ok: true, items };
        })()
        """
        #expect(service.errorLogReadScript(clear: false) == expected)
    }

    @Test("storageSnapshotScript emits the exact frozen wire script")
    func storageSnapshotScriptExact() {
        let expected = """
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
        #expect(service.storageSnapshotScript() == expected)
    }

    @Test("storageRestoreScript emits the exact frozen wire script and embeds the literal verbatim")
    func storageRestoreScriptExact() {
        // The caller renders the saved snapshot via jsonLiteral and passes it
        // through verbatim; assert it is embedded unchanged inside the frozen body.
        let storageLiteral = service.jsonLiteral(["local": ["a": "1"], "session": [:] as [String: Any]])
        let expected = """
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
        #expect(service.storageRestoreScript(storageLiteral: storageLiteral) == expected)
    }
}
