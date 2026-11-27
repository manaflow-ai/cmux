@testable import CmuxNextBrowser
import Testing

/// What a page area shows between a navigation committing and its document
/// painting (`CEFTab+LoadingBackground`, `CEFFirstPaintBridge`).
@Suite struct BrowserLoadingBackgroundTests {
    private static let theme: UInt32 = 0xFF1E_1E2E
    private static let newTab: UInt32 = 0xFF18_1825
    private static let document: UInt32 = 0xFF0B_5D3B

    /// The order the page's own paint takes the page area over.
    @Test func theBaseIsTheThemeColorUntilTheDocumentPaints() {
        func base(pastFirstRealPage: Bool, settled: Bool, document: UInt32?) -> UInt32 {
            PageBackground.chromiumARGB(pastFirstRealPage: pastFirstRealPage, documentSettled: settled,
                                        document: document, newTab: Self.newTab, loading: Self.theme)
        }
        // Before any real page: the New Tab surface, settled or not.
        #expect(base(pastFirstRealPage: false, settled: false, document: nil) == Self.newTab)
        #expect(base(pastFirstRealPage: false, settled: true, document: Self.document) == Self.newTab)
        // Committed and not painted yet: the theme color, never the engine's white.
        #expect(base(pastFirstRealPage: true, settled: false, document: nil) == Self.theme)
        #expect(base(pastFirstRealPage: true, settled: false, document: Self.document) == Self.theme)
        // Painted: the document's own color, and the web's white when it has none.
        #expect(base(pastFirstRealPage: true, settled: true, document: Self.document) == Self.document)
        #expect(base(pastFirstRealPage: true, settled: true, document: nil) == PageBackground.engineDefaultARGB)
    }

    /// The hand-over is first contentful paint, not the end of the load: the
    /// theme color is Chromium's canvas fill for as long as it is the base, so
    /// holding it past the first paint would put it under a page that is
    /// already being read.
    @Test func theMainFramesFirstContentfulPaintEndsTheHold() {
        let event = Self.lifecycle("firstContentfulPaint", frame: "MAIN")
        #expect(CEFFirstPaintBridge.isFirstContentfulPaint(event, mainFrame: "MAIN"))
        // Before the main frame is known every frame counts, so a hand-over is
        // never missed; the worst case is the old load-end behavior.
        #expect(CEFFirstPaintBridge.isFirstContentfulPaint(event, mainFrame: nil))
    }

    @Test func aSubframesPaintIsNotThePages() {
        let event = Self.lifecycle("firstContentfulPaint", frame: "IFRAME")
        #expect(!CEFFirstPaintBridge.isFirstContentfulPaint(event, mainFrame: "MAIN"))
    }

    /// Every other lifecycle event leaves the base alone: `init` and
    /// `firstPaint` come before any content is on screen, and `load` and
    /// `networkIdle` come long after.
    @Test func otherMessagesDoNotEndTheHold() {
        for name in ["init", "firstPaint", "firstMeaningfulPaint", "load", "DOMContentLoaded", "networkIdle"] {
            #expect(!CEFFirstPaintBridge.isFirstContentfulPaint(Self.lifecycle(name, frame: "MAIN"), mainFrame: "MAIN"))
        }
        #expect(!CEFFirstPaintBridge.isFirstContentfulPaint("", mainFrame: "MAIN"))
        #expect(!CEFFirstPaintBridge.isFirstContentfulPaint("not json", mainFrame: "MAIN"))
        // A page that merely mentions the name in its own binding payload.
        let impostor = #"{"method":"Runtime.bindingCalled","params":{"name":"cmuxMedia","payload":"firstContentfulPaint"}}"#
        #expect(!CEFFirstPaintBridge.isFirstContentfulPaint(impostor, mainFrame: "MAIN"))
        // The right name under the wrong method.
        let wrongMethod = #"{"method":"Page.frameNavigated","params":{"name":"firstContentfulPaint","frameId":"MAIN"}}"#
        #expect(!CEFFirstPaintBridge.isFirstContentfulPaint(wrongMethod, mainFrame: "MAIN"))
    }

    private static func lifecycle(_ name: String, frame: String) -> String {
        #"{"method":"Page.lifecycleEvent","params":{"frameId":"\#(frame)","loaderId":"L1","name":"\#(name)","timestamp":1.5}}"#
    }
}
