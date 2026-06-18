import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserControlService storage scripts")
struct BrowserControlServiceStorageScriptsTests {
    let service = BrowserControlService()

    @Test("storageType defaults to local and recognizes session")
    func storageTypeNormalization() {
        #expect(service.storageType(params: [:]) == "local")
        #expect(service.storageType(params: ["storage": "local"]) == "local")
        #expect(service.storageType(params: ["storage": "Session"]) == "session")
        // Legacy `type` key is consulted only when `storage` is absent.
        #expect(service.storageType(params: ["type": "session"]) == "session")
        #expect(service.storageType(params: ["storage": "local", "type": "session"]) == "local")
        // Any unrecognized value maps to local.
        #expect(service.storageType(params: ["storage": "cookies"]) == "local")
    }

    @Test("storageType trims whitespace and ignores empty/non-string like v2String")
    func storageTypeTrimAndEmptyFallthrough() {
        // Whitespace is trimmed before the session/local comparison.
        #expect(service.storageType(params: ["storage": "  session  "]) == "session")
        #expect(service.storageType(params: ["storage": "\tSESSION\n"]) == "session")
        // An empty or whitespace-only `storage` is treated as absent, so the
        // legacy `type` key is consulted next (matching v2String's empty-to-nil).
        #expect(service.storageType(params: ["storage": "   ", "type": "session"]) == "session")
        #expect(service.storageType(params: ["storage": "", "type": "session"]) == "session")
        // A non-string value is ignored, falling through to the default.
        #expect(service.storageType(params: ["storage": 42]) == "local")
        // Both keys empty/absent fall through to the local default.
        #expect(service.storageType(params: ["storage": "  ", "type": "  "]) == "local")
    }

    @Test("storageGetScript emits the exact frozen wire script for the whole-area case")
    func storageGetScriptExactWholeArea() {
        // The browser RPC wire format is frozen; assert the full emitted script,
        // not just fragments, so any drift in the page-world JS is caught.
        let expected = """
        (() => {
          const type = String("local");
          const key = null;
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          if (key == null) {
            const out = {};
            for (let i = 0; i < st.length; i++) {
              const k = st.key(i);
              out[k] = st.getItem(k);
            }
            return { ok: true, value: out };
          }
          return { ok: true, value: st.getItem(String(key)) };
        })()
        """
        #expect(service.storageGetScript(storageType: "local", key: nil) == expected)
    }

    @Test("storageSetScript emits the exact frozen wire script")
    func storageSetScriptExact() {
        let expected = """
        (() => {
          const type = String("session");
          const key = String("token");
          const value = "v";
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          st.setItem(key, value == null ? '' : String(value));
          return { ok: true };
        })()
        """
        #expect(service.storageSetScript(storageType: "session", key: "token", valueLiteral: "\"v\"") == expected)
    }

    @Test("storageClearScript emits the exact frozen wire script")
    func storageClearScriptExact() {
        let expected = """
        (() => {
          const type = String("local");
          const st = type === 'session' ? window.sessionStorage : window.localStorage;
          if (!st) return { ok: false, error: 'not_available' };
          st.clear();
          return { ok: true };
        })()
        """
        #expect(service.storageClearScript(storageType: "local") == expected)
    }

    @Test("storageGetScript reads the whole area when key is nil")
    func storageGetWholeArea() {
        let script = service.storageGetScript(storageType: "local", key: nil)
        #expect(script.hasPrefix("(() => {"))
        #expect(script.contains("const type = String(\"local\");"))
        #expect(script.contains("const key = null;"))
        #expect(script.contains("type === 'session' ? window.sessionStorage : window.localStorage"))
        #expect(script.contains("for (let i = 0; i < st.length; i++)"))
        #expect(script.contains("return { ok: false, error: 'not_available' };"))
    }

    @Test("storageGetScript reads a single key when provided")
    func storageGetSingleKey() {
        let script = service.storageGetScript(storageType: "session", key: "token")
        #expect(script.contains("const type = String(\"session\");"))
        #expect(script.contains("const key = \"token\";"))
        #expect(script.contains("return { ok: true, value: st.getItem(String(key)) };"))
    }

    @Test("storageSetScript writes the value literal verbatim")
    func storageSet() {
        let script = service.storageSetScript(storageType: "local", key: "k", valueLiteral: "\"v\"")
        #expect(script.contains("const type = String(\"local\");"))
        #expect(script.contains("const key = String(\"k\");"))
        #expect(script.contains("const value = \"v\";"))
        #expect(script.contains("st.setItem(key, value == null ? '' : String(value));"))
    }

    @Test("storageClearScript clears the chosen area")
    func storageClear() {
        let script = service.storageClearScript(storageType: "session")
        #expect(script.contains("const type = String(\"session\");"))
        #expect(script.contains("st.clear();"))
        #expect(script.contains("return { ok: true };"))
    }
}
