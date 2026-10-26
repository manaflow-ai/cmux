#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The out-of-process Chromium host stays off until a developer turns it on: Chromium tabs run in
/// process (Japanese IME, find, drag and permission prompts do not work in the host yet).
@MainActor
@Suite struct ChromiumHostDefaultOffTests {
    /// Debug Settings as the app holds them, with nothing changed.
    private static func defaults() -> TunableStore {
        let store = TunableStore()
        store.register(BrowserHostTunables.all)
        store.activate(file: nil)
        return store
    }

    @Test func theHostIsOffByDefault() {
        #expect(BrowserHostTunables.helperPrototype.defaultValue == false)
        #expect(BrowserHostTunables.helperPrototype.value(in: Self.defaults()) == false)
    }

    @Test func withDefaultSettingsNoHostStarts() {
        var asked = 0
        let prototype = ChromiumHostPrototype(makeConfiguration: {
            asked += 1
            return ChromiumHostConfiguration(executable: URL(filePath: "/bin/true"), arguments: [])
        }, tunables: Self.defaults())
        let reply = prototype.open("https://example.com/", over: NSView(frame: .zero), focus: false)
        #expect(reply["error"] as? String == "browserHost.helperPrototype is off")
        #expect(asked == 0)
        #expect(prototype.report["phase"] as? String == "none")
    }
}
#endif
