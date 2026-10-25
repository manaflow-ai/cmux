import Foundation
import Testing
@testable import CmuxNextBrowser

/// The New Tab and every agent chat are one origin (`cmux-page://cmux.agent`). Chrome puts at most 2 main
/// frames of a site in one renderer (ProcessPerSiteMainFrameThreshold, content_features.cc), so 5 chats took
/// 3 renderers. The cmux-page entry of the fork's per-site sharing table raises that site's cap to 8 and
/// leaves web tabs at Chrome's 2. Only a fork with the renderer paths (API 29) has the switch, and only
/// there does no page hold a DevTools session that would end the sharing.
@Suite struct CEFSwitchesTests {
    private func arguments(forkAPI: Int32) -> [String] {
        let features = CEFForkFeatures(forkAPIVersion: forkAPI, shimHasRendererPaths: true)
        return CEFSwitches.current(forkAPIVersion: forkAPI, rendererPaths: features.rendererPaths,
                                   bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
    }

    @Test func aForkWithTheRendererPathsCapsTheCmuxPageSiteAtEightMainFrames() {
        #expect(arguments(forkAPI: 29).contains("cmux-process-per-site-main-frame-thresholds=cmux-page:8"))
    }

    @Test func aForkWithoutTheRendererPathsGetsNoPerSiteTable() {
        #expect(!arguments(forkAPI: 28).contains { $0.hasPrefix(CEFSwitches.processPerSiteMainFrameThresholdsSwitch) })
    }

    @Test func aShimWithoutTheRendererPathsGetsNoPerSiteTable() {
        let switches = CEFSwitches.current(forkAPIVersion: 29, rendererPaths: false,
                                           bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
        #expect(!switches.contains { $0.hasPrefix(CEFSwitches.processPerSiteMainFrameThresholdsSwitch) })
    }

    /// One table, one entry: web tabs keep Chrome's own cap, and the switch is passed once.
    @Test func webTabsKeepChromesCapOfTwo() {
        #expect(CEFSwitches.processPerSiteMainFrameThresholds == [.init(scheme: "cmux-page", mainFrames: 8)])
        #expect(arguments(forkAPI: 29).filter { $0.hasPrefix(CEFSwitches.processPerSiteMainFrameThresholdsSwitch) }.count == 1)
    }
}
