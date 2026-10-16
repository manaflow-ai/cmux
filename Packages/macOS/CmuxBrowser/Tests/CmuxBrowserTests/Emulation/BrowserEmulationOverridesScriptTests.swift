import CmuxBrowser
import Testing

@Suite
struct BrowserEmulationOverridesScriptTests {
    @Test("offline emulation rejects fetch before Chromium networking can escape")
    func offlineScriptGuardsFetch() {
        let script = BrowserEmulationOverrides(offline: true).pageScript(dispatchesChangeEvents: false)
        #expect(script.contains("state.nativeFetch"))
        #expect(script.contains("Failed to fetch"))
        #expect(script.contains("globalThis.fetch = function"))
    }
}
