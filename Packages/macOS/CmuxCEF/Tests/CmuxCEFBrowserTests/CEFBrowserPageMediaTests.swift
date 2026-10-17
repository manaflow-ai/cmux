import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFBrowser

/// Chromium tabs report media playback (the tab's speaker) through the shared
/// media-playback hook and mute through Chromium's own audio mute.
@MainActor
@Suite
struct CEFBrowserPageMediaTests {
    private func makePage() -> CEFBrowserPage {
        let browser = CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID()))
        return CEFBrowserPage(
            browser: browser,
            shim: { nil },
            devToolsLayoutStore: BrowserDevToolsLayoutStore(
                defaults: UserDefaults(suiteName: "CEFBrowserPageMediaTests.\(UUID().uuidString)")!
            )
        )
    }

    @Test func setupRunsTheHookInAnIsolatedWorldWithItsBinding() throws {
        let calls = CEFBrowserPage.mediaPlaybackSetupCalls()
        #expect(calls.map(\.method) == [
            "Page.enable",
            "Page.addScriptToEvaluateOnNewDocument",
            "Runtime.addBinding",
        ])
        let script = calls[1].params
        #expect(script["worldName"] as? String == CEFBrowserPage.mediaPlaybackWorld)
        let source = try #require(script["source"] as? String)
        #expect(source.contains("typeof \(CEFBrowserPage.mediaPlaybackBinding) === 'function'"))
        let binding = calls[2].params
        #expect(binding["name"] as? String == CEFBrowserPage.mediaPlaybackBinding)
        #expect(binding["executionContextName"] as? String == CEFBrowserPage.mediaPlaybackWorld)
    }

    @Test func bindingCallsBecomeReports() {
        let payload = #"{\"frameID\":\"f\",\"playing\":true,\"audible\":true,\"pip\":false}"#
        let message = #"{"method":"Runtime.bindingCalled","params":{"name":"cmuxMediaPlayback","payload":"\#(payload)","executionContextId":3}}"#
        #expect(CEFBrowserPage.mediaPlaybackSignal(forProtocolMessage: message)
            == .report(BrowserMediaPlaybackReport(frameID: "f", isPlaying: true, isAudible: true)))
        // Another binding (automation's) is not the hook's.
        let other = #"{"method":"Runtime.bindingCalled","params":{"name":"other","payload":"\#(payload)"}}"#
        #expect(CEFBrowserPage.mediaPlaybackSignal(forProtocolMessage: other) == nil)
        #expect(CEFBrowserPage.mediaPlaybackSignal(forProtocolMessage: #"{"id":1,"result":{}}"#) == nil)
    }

    @Test func frameNavigationsRefreshTheBindingAndAMainDocumentResets() {
        let main = #"{"method":"Page.frameNavigated","params":{"frame":{"id":"A","url":"https://a.test/"},"type":"Navigation"}}"#
        #expect(CEFBrowserPage.mediaPlaybackSignal(forProtocolMessage: main) == .mainDocumentCommitted)
        let child = #"{"method":"Page.frameNavigated","params":{"frame":{"id":"B","parentId":"A","url":"https://b.test/"}}}"#
        #expect(CEFBrowserPage.mediaPlaybackSignal(forProtocolMessage: child) == .frameChanged)
        let stopped = #"{"method":"Page.frameStoppedLoading","params":{"frameId":"B"}}"#
        #expect(CEFBrowserPage.mediaPlaybackSignal(forProtocolMessage: stopped) == .frameChanged)
    }

    @Test func muteIsKeptForTheBrowserChromiumCreatesLater() {
        let page = makePage()
        defer { page.close() }
        #expect(page.capabilities.contains(.mediaMuting))
        #expect(!page.isMuted)
        page.isMuted = true
        #expect(page.isMuted)
        #expect(page.browser.isAudioMuted)
        page.isMuted = false
        #expect(!page.browser.isAudioMuted)
    }
}
