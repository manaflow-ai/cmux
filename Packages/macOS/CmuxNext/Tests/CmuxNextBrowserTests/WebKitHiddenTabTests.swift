import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// p14-energy-059 (`webkitHiddenTabs`): a WebKit tab the content lifecycle hides is hidden to WebKit through its web
/// view's `isHidden` (``WebKitPageVisibility``), so the page reports `document.visibilityState == "hidden"`; a show
/// unhides it in the same call and reloads nothing; a page with audible or Picture in Picture media or a camera or
/// microphone capture stays visible; with the feature off nothing changes.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct WebKitHiddenTabTests {
    // MARK: The rule

    @Test func onlyAHiddenPageWithNothingToKeepItShownIsHidden() {
        let hidden = WebKitPageVisibility(followsContent: true, contentHidden: true)
        #expect(hidden.hidesPage)
        #expect(!WebKitPageVisibility(followsContent: true, contentHidden: false).hidesPage, "a shown page was hidden")
        #expect(!WebKitPageVisibility(followsContent: false, contentHidden: true).hidesPage, "the feature off hid a page")
        var playing = hidden
        playing.playsMedia = true
        #expect(!playing.hidesPage, "a page that plays media was hidden")
        var capturing = hidden
        capturing.captures = true
        #expect(!capturing.hidesPage, "a page that captures was hidden")
    }

    // MARK: The tab

    @Test func aHiddenTabHidesItsWebViewAndAShowUnhidesItInTheSameCall() {
        let tab = Self.engine(hides: true).makeWebKitTab()
        defer { tab.close() }
        #expect(!tab.webView.isHidden, "a new tab starts hidden")
        tab.setContentVisible(false)
        #expect(tab.webView.isHidden)
        #expect(!tab.contentView.isHidden, "the container, which the chrome places, was hidden")
        tab.setContentVisible(true)
        #expect(!tab.webView.isHidden, "the show waited")
    }

    @Test func withTheFeatureOffAHiddenTabKeepsItsWebViewShown() {
        let tab = Self.engine(hides: false).makeWebKitTab()
        defer { tab.close() }
        tab.setContentVisible(false)
        #expect(!tab.webView.isHidden)
    }

    @Test func anAudibleTabStaysShownWhileHiddenAndHidesWhenItsAudioStops() {
        let tab = Self.engine(hides: true).makeWebKitTab()
        defer { tab.close() }
        tab.apply(.mediaChanged(Self.song))
        tab.setContentVisible(false)
        #expect(tab.isAudible)
        #expect(!tab.webView.isHidden, "an audible tab was hidden to WebKit")
        tab.apply(.mediaChanged(nil))
        #expect(tab.webView.isHidden, "a hidden tab whose audio stopped stayed visible")
        tab.apply(.mediaChanged(Self.song))
        #expect(!tab.webView.isHidden, "a hidden tab whose audio started stayed hidden")
        tab.setContentVisible(true)
        #expect(!tab.webView.isHidden)
    }

    @Test func aMutedTabIsHiddenButItsPictureInPictureKeepsItShown() {
        let tab = Self.engine(hides: true).makeWebKitTab()
        defer { tab.close() }
        tab.apply(.mediaChanged(BrowserMediaState(title: "clip", isPlaying: true, isMuted: true, isVideo: true)))
        tab.setContentVisible(false)
        #expect(tab.webView.isHidden, "a muted page kept the hidden tab visible")
        tab.apply(.mediaChanged(BrowserMediaState(title: "clip", isPlaying: true, isMuted: true, isVideo: true, isPictureInPicture: true)))
        #expect(!tab.webView.isHidden, "a page whose video floats in Picture in Picture was hidden")
    }

    // MARK: WebKit's view of it

    @Test func aHiddenTabReportsHiddenAndItsShowReloadsNothing() async throws {
        let live = try await LivePage()
        defer { live.close() }
        let tab = live.tab
        #expect(try await tab.evaluate("window.cmuxMarker = 59", world: .page, gesture: .cmux) == .number(59))
        let starts = Starts()
        let observer = tab.observeNavigationEvents { if case .started = $0 { starts.count += 1 } }
        defer { tab.removeNavigationObserver(observer) }

        tab.setContentVisible(false)
        #expect(try await live.visibility(becomes: "hidden") == "hidden", "WebKit did not report the hidden tab hidden")
        tab.setContentVisible(true)
        #expect(try await live.visibility(becomes: "visible") == "visible", "WebKit did not report the shown tab visible")

        #expect(starts.count == 0, "the show started a navigation")
        #expect(try await tab.evaluate("window.cmuxMarker", world: .page, gesture: .cmux) == .number(59), "the show reloaded the page")
    }

    @Test func anAudibleHiddenTabStaysVisibleToWebKit() async throws {
        let live = try await LivePage()
        defer { live.close() }
        let tab = live.tab
        tab.apply(.mediaChanged(Self.song))
        tab.setContentVisible(false)
        // Waits for a hide that must not come; a hide reaches the page well inside the wait (the test above).
        #expect(try await live.visibility(becomes: "hidden", within: 1000) == "visible", "the audible hidden tab was hidden to WebKit")
        tab.apply(.mediaChanged(nil))
        #expect(try await live.visibility(becomes: "hidden") == "hidden", "the hidden tab whose audio stopped stayed visible")
    }

    // MARK: Helpers

    static let song = BrowserMediaState(title: "song", isPlaying: true)

    static func engine(hides: Bool) -> WebKitEngine {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        engine.hidesHiddenTabs = hides
        return engine
    }

    @MainActor final class Starts {
        var count = 0
    }

    /// A loaded tab with the feature on, in a window on screen.
    @MainActor final class LivePage {
        let tab: WebKitTab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)

        init() async throws {
            _ = NSApplication.shared
            tab = WebKitHiddenTabTests.engine(hides: true).makeWebKitTab()
            window.isReleasedWhenClosed = false
            let content = try #require(window.contentView)
            tab.contentView.frame = content.bounds
            content.addSubview(tab.contentView)
            window.orderFrontRegardless()
            tab.load(try #require(URL(string: "data:text/html,%3Ctitle%3Ehidden%3C/title%3E%3Cp%3Ehidden%20tab%3C/p%3E")))
            try #require(await tab.when(phase: .finished, timeout: .seconds(30)), "the page did not load")
            try #require(try await visibility(becomes: "visible") == "visible", "the page is not visible in a window on screen")
        }

        /// The page's `document.visibilityState` once it is `want`, or after `within` ms whatever it is then.
        func visibility(becomes want: String, within: Double = 5000) async throws -> String? {
            try await tab.callFunction(Self.visibilityBody, arguments: ["want": .string(want), "within": .number(within)],
                                       world: .page, gesture: .cmux).stringValue
        }

        func close() {
            tab.close()
            window.close()
        }

        static let visibilityBody = """
        if (document.visibilityState === want) return want;
        return await new Promise((resolve) => {
          const check = () => {
            if (document.visibilityState !== want) return;
            document.removeEventListener('visibilitychange', check);
            resolve(want);
          };
          document.addEventListener('visibilitychange', check);
          setTimeout(() => resolve(document.visibilityState), within);
        });
        """
    }
}
