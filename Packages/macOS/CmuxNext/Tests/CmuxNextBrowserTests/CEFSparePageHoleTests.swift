import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

extension CEFSparePageSuites {
    /// cmux-ad m37, Lawrence 2026-11-05 ("chrome bg is black on cmd shift l aka new tab"): with a window background
    /// picture in dark mode, a new Chromium tab showed its page area as an opaque dark box instead of the window
    /// picture. Real-app films on 155b3f25 (layer hosting on): with `browserPage.sparePage` on the tab took the spare
    /// page (`debug.cef` `spare_pages_taken` 1) and the box showed; with it off the picture showed. A tab before its
    /// first real page is a hole in its page window (`CEFTab.applyOcclusion`), and with layer hosting its hosted page
    /// shows no pixels there (`CEFLayerHosting.pageHole`, #36908). These tests drive the spare page's two takes
    /// (`CEFPaneHost.joinSparePage`, `CEFSpareWindow.takePage`) with the stand-in shim and read that visible result.
    @MainActor @Suite struct CEFSparePageHoleTests {
        typealias Rig = CEFSparePageTests

        /// How the new tab reaches the spare page.
        enum Take: String, CaseIterable, CustomTestStringConvertible {
            /// A pane whose Chromium window is live: the spare page moves into it (`tabMoveToWindow`).
            case movedIntoALivePane
            /// A pane's first Chromium tab: the pane takes the spare window, and the page already in it.
            case paneTookTheSpareWindow
            var testDescription: String { rawValue }
        }

        /// The end-of-turn work a take or a window leaves (the hosting request, the placeholder's close) runs now.
        static func runTurns() {
            for _ in 0..<8 { RunLoop.main.run(mode: .default, before: .distantPast) }
        }

        /// The new tab that took the spare page, before its first real page, is a hole: its hosted page shows no
        /// pixels and its page window has the whole web contents as an occlusion rect, as a tab whose page
        /// `tab_add` made.
        @Test(arguments: Take.allCases)
        func aNewTabThatTookTheSparePageIsAHoleBeforeItsFirstRealPage(_ take: Take) throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            SpareSpy.hostingContext = 7
            #expect(CEFHostingSwitch.hostingWanted, "SETUP: layer hosting is off")
            #expect(CEFSpareWindow.makesPages, "SETUP: the spare page switch is off")

            var livePane: (host: CEFPaneHost, container: NSView)?
            if take == .movedIntoALivePane {
                let live = try Rig.liveHost(runtime)
                livePane = (live.0, live.2)
                Self.runTurns()
            }
            let page = try Rig.spareWithPage(runtime)
            Self.runTurns()

            let shown: CEFPaneHost
            let container: NSView
            if let livePane {
                (shown, container) = livePane
            } else {
                shown = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
                #expect(shown.isLive && shown.placeholder != nil, "SETUP: the pane did not take the live spare window")
                shown.endOfTurn = { $0() }
                container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            }
            let tab = CEFTab(id: .random(), profile: .default, host: shown, runtime: runtime)
            shown.add(tab)
            shown.present(tab, in: container)
            shown.createDeferred()
            Self.runTurns()
            try #require(tab.browserID == page, "SETUP: the new tab did not take the spare page")
            #expect(runtime.spareWindow.pagesTaken == 1)
            #expect(!tab.pastFirstRealPage, "a new tab with nothing loaded is before its first real page")
            #expect(shown.visibleTab === tab)

            // What the person sees: the layout's occlusion pass for the shown tab.
            tab.applyOcclusion()
            let hostView = shown.hostView
            let hosted = try #require(hostView.subviews.compactMap { $0 as? CEFHostedPageView }.first,
                                      "the page that took the spare page is not layer-hosted: it draws Chromium's opaque page in its own window")
            #expect(hostView.layerHosting.page === hosted)
            #expect(CEFHostedPageHoleTests.showsNoPixels(hosted), "the hosted page shows Chromium's opaque page color over the window picture")
            #expect(hostView.occlusionRects == [hostView.bounds], "the page window's web contents are no hole")
        }
    }
}
