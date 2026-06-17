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
