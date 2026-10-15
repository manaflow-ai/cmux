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

    @Test func answersDeniedForPermissionAndBothRequestForms() {
        let source = BrowserNotificationDenialScript.source
        #expect(source.contains(#"get: () => "denied""#))
        #expect(source.contains(#"callback("denied")"#))
        #expect(source.contains(#"Promise.resolve("denied")"#))
        // Never throws into the page: everything is guarded.
        #expect(source.contains("try {"))
    }
}
