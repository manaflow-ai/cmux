import AppKit
@testable import CmuxNextBrowser
import Testing

/// CEF collapses Cmd-click and middle-click into NEW_BACKGROUND_TAB. The
/// recorded page click must restore the gesture before window policy turns it
/// into a cmux tab placement.
struct CEFWindowPolicyTests {
    private let mapping = BrowserLinkClickMapping(cmdClick: .linkPlacement,
                                                   cmdShiftClick: .foregroundTab,
                                                   shiftClick: .newWindow,
                                                   optionClick: .download,
                                                   middleClick: .backgroundTab)

    private func click(_ gesture: BrowserLinkGesture) -> CEFLinkClickRecord {
        CEFLinkClickRecord(gesture: gesture, timestamp: 1)
    }

    private func placement(_ disposition: CEFDisposition, _ gesture: BrowserLinkGesture) -> CEFLinkPlacement {
        CEFLinkClicks.placement(for: disposition, userGesture: true, click: click(gesture), now: 1, mapping: mapping)
    }

    private func request(_ disposition: CEFDisposition) -> CEFWindowRequest {
        CEFWindowRequest(kind: .tab, disposition: disposition, sourceBrowser: 11, bounds: nil,
                         url: "https://example.com/", userGesture: true, profilePath: "/profile")
    }

    private var candidate: CEFWindowCandidate {
        CEFWindowCandidate(anchor: 7, profilePath: "/profile", holdsSource: true, lastShown: true, visible: true)
    }

    @Test func middleClickUsesItsBackgroundTabSetting() {
        #expect(placement(.newBackgroundTab, .middle) == .tab(.backgroundTab))
    }

    @Test func commandClickUsesItsOwnSetting() {
        #expect(placement(.newBackgroundTab, .cmd) == .tab(.linkPlacement))
    }

    @Test func shiftedCommandAndMiddleClicksOpenForegroundTabs() {
        #expect(placement(.newForegroundTab, .cmdShift) == .tab(.foregroundTab))
        #expect(placement(.newForegroundTab, .middleShift) == .tab(.foregroundTab))
    }

    @Test func shiftClickUsesItsNewWindowSetting() {
        #expect(placement(.newWindow, .shift) == .tab(.newWindow))
    }

    @Test func optionClickUsesItsDownloadSetting() {
        #expect(placement(.saveToDisk, .option) == .download)
    }

    @Test func policyKeepsMiddleClickBackgroundDispositionWhenItInserts() {
        let links = CEFLinkContext(mapping: mapping,
                                   clicks: [11: click(.middle)], now: 1)
        let decision = CEFWindowPolicy.decide(request(.newBackgroundTab), candidates: [candidate], links: links)
        #expect(decision == .insert(anchor: 7, disposition: .backgroundTab))
    }
}
