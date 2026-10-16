import Testing
@testable import CmuxBrowser

@Suite("Notification denial script")
struct BrowserNotificationDenialScriptTests {
    @Test func runsBeforePageScriptsInEveryFrameOfThePageWorld() {
        let script = BrowserNotificationDenialScript.userScript
        #expect(script.injectionTime == .documentStart)
        #expect(!script.isMainFrameOnly)
        #expect(script.world == .page)
    }

    @Test func fallbackDefinesASettlingDeniedApi() {
        let source = BrowserNotificationDenialScript.source
        #expect(source.contains(#"get: () => "denied""#))
        #expect(source.contains(#"callback("denied")"#))
        #expect(source.contains(#"Promise.resolve("denied")"#))
        // Chromium removes the API under --disable-notifications: the script
        // defines one only when it is absent.
        #expect(source.contains(#"typeof N !== "function""#))
        #expect(source.contains(#"Object.defineProperty(globalThis, "Notification""#))
        #expect(source.contains(#"if (typeof N !== "function")"#))
        // Never throws into the page: everything is guarded.
        #expect(source.contains("try {"))
    }
}
