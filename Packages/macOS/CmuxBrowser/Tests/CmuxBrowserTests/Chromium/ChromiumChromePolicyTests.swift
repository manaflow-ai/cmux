import Foundation
import Testing

@testable import CmuxBrowser

@Suite struct ChromiumNetErrorTests {
    @Test func abortedLoadsShowNothing() {
        let error = ChromiumNetError(code: ChromiumNetError.abortedCode, text: "net::ERR_ABORTED")
        #expect(error.presentation(chromiumShowsPage: true) == .nothing)
        #expect(error.presentation(chromiumShowsPage: false) == .nothing)
    }

    @Test func chromiumsOwnPageIsNeverCovered() {
        for code in [-105, -102, -118, -106, -202, -310, -2] {
            let error = ChromiumNetError(code: code, text: "net::ERR_X")
            #expect(error.presentation(chromiumShowsPage: true) == .chromiumPage)
            #expect(error.presentation(chromiumShowsPage: false) == .cmuxPage)
        }
    }

    @Test func classifiesTitlesLikeWebKitErrorPages() {
        #expect(ChromiumNetError(code: -105, text: "").title == .cantReach)
        #expect(ChromiumNetError(code: -137, text: "").detail == .addressNotFound)
        #expect(ChromiumNetError(code: -102, text: "").detail == .refused)
        #expect(ChromiumNetError(code: -7, text: "").detail == .timedOut)
        #expect(ChromiumNetError(code: -118, text: "").title == .cantReach)
        #expect(ChromiumNetError(code: -106, text: "").title == .noInternet)
        #expect(ChromiumNetError(code: -202, text: "").title == .insecure)
        #expect(ChromiumNetError(code: -202, text: "").isCertificateError)
        #expect(ChromiumNetError(code: -310, text: "").title == .cantOpen)
        #expect(ChromiumNetError(code: -310, text: "").detail == .generic)
    }

    @Test func errorNameDropsThePrefixAndFallsBackToTheCode() {
        #expect(ChromiumNetError(code: -105, text: "net::ERR_NAME_NOT_RESOLVED").name == "ERR_NAME_NOT_RESOLVED")
        #expect(ChromiumNetError(code: -999, text: "").name == "net::-999")
        #expect(ChromiumNetError(code: -999, text: "ERR_FOO").name == "ERR_FOO")
    }
}

@Suite struct ChromiumPageGoneTests {
    @Test func mapsEveryCEFTerminationStatus() {
        #expect(ChromiumPageGone(cefStatus: 0, code: 0).reason == .abnormal)
        #expect(ChromiumPageGone(cefStatus: 1, code: 0).reason == .killed)
        #expect(ChromiumPageGone(cefStatus: 2, code: 11).reason == .crashed)
        #expect(ChromiumPageGone(cefStatus: 3, code: 0).reason == .outOfMemory)
        #expect(ChromiumPageGone(cefStatus: 4, code: 0).reason == .launchFailed)
        #expect(ChromiumPageGone(cefStatus: 5, code: 0).reason == .integrityFailure)
        #expect(ChromiumPageGone(cefStatus: 42, code: 0).reason == .abnormal)
        #expect(ChromiumPageGone(cefStatus: 2, code: 0).code == nil)
    }

    @Test func describesSignalsAndExitStatuses() {
        #expect(ChromiumPageGone(reason: .crashed, code: 11).codeDescription == "SIGSEGV")
        #expect(ChromiumPageGone(reason: .killed, code: 9).codeDescription == "SIGKILL")
        #expect(ChromiumPageGone(reason: .crashed, code: 31).codeDescription == "signal 31")
        #expect(ChromiumPageGone(reason: .abnormal, code: 3 << 8).codeDescription == "exit 3")
        #expect(ChromiumPageGone(reason: .abnormal, code: nil).codeDescription == nil)
        #expect(ChromiumPageGone(reason: .abnormal, code: 0).errorCodeLine == nil)
    }

    @Test func usesChromesWording() {
        let crash = ChromiumPageGone(reason: .crashed, code: 11)
        #expect(crash.title(repeated: false) == "Aw, Snap!")
        #expect(crash.message(repeated: false) == "Something went wrong while displaying this webpage.")
        #expect(crash.errorCodeLine == "Error code: SIGSEGV")
    }

    @Test func repeatedCrashesChangeTheTitleAndOutOfMemoryAdvice() {
        let crash = ChromiumPageGone(reason: .crashed)
        let oom = ChromiumPageGone(reason: .outOfMemory)
        #expect(crash.title(repeated: true) == "Can\u{2019}t open this page")
        #expect(crash.message(repeated: true) == crash.message(repeated: false))
        #expect(oom.message(repeated: false) == crash.message(repeated: false))
        #expect(oom.message(repeated: true) == "Try closing other tabs or programs to free up memory.")
    }

    @Test func crashHistoryCountsRepeatsWithinTenSeconds() {
        var history = ChromiumCrashHistory()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(!history.record(at: start))
        #expect(history.record(at: start.addingTimeInterval(9.9)))
        #expect(!history.record(at: start.addingTimeInterval(9.9 + 10)))
        #expect(history.record(at: start.addingTimeInterval(9.9 + 10 + 1)))
    }
}

@Suite struct ChromiumKeyWindowFactsTests {
    typealias Facts = ChromiumKeyWindowFacts

    @Test func unclickedPageWindowGivesTheKeysBack() {
        #expect(Facts(parent: .thisWindow, isChromiumPage: true).decision == .unchosenPage)
        #expect(Facts(parent: .thisWindow, isChromiumPage: true, clicked: true, overPane: false).decision
            == .unchosenPage)
    }

    @Test func clickIntoPlacedPageChoosesIt() {
        #expect(Facts(parent: .thisWindow, isChromiumPage: true, clicked: true, overPane: true).decision
            == .chosenPage)
    }

    @Test func devToolsKeepTheKeys() {
        #expect(Facts(parent: .thisWindow, isChromiumPage: true, isDevTools: true).decision == .devTools)
    }

    @Test func otherOwnedWindowOverPaneReapplies() {
        #expect(Facts(parent: .thisWindow, isChromiumPage: false, overPane: true).decision == .reapply)
        #expect(Facts(parent: .thisWindow, isChromiumPage: false).decision == .ignore)
    }

    @Test func parentlessPageBelongsOnlyToTheActiveWindow() {
        #expect(Facts(parent: .none, isChromiumPage: true).decision == .unchosenPage)
        #expect(Facts(parent: .none, isChromiumPage: true, thisWindowIsActive: false).decision == .ignore)
        #expect(Facts(parent: .none, isChromiumPage: true).shouldReclaim)
        #expect(!Facts(parent: .none, isChromiumPage: true, thisWindowIsActive: false).shouldReclaim)
        #expect(!Facts(parent: .none, isChromiumPage: false).shouldReclaim)
    }

    @Test func panelsAndOtherWindowsAreIgnored() {
        #expect(Facts(parent: .thisWindow, isPanel: true, isChromiumPage: true).decision == .ignore)
        #expect(Facts(parent: .other, isChromiumPage: true, clicked: true, overPane: true).decision == .ignore)
        #expect(!Facts(parent: .other, isChromiumPage: true).shouldReclaim)
    }
}

@Suite struct ChromiumWindowOpenRouteTests {
    private func route(
        _ disposition: ChromiumWindowOpenDisposition,
        features: Bool = false,
        gesture: Bool = true,
        opener: Bool = true,
        url: Bool = true
    ) -> ChromiumWindowOpenRoute {
        ChromiumWindowOpenRoute.route(
            disposition: disposition, hasWindowFeatures: features, userGesture: gesture, hasOpener: opener, hasURL: url
        )
    }

    @Test func scriptedPopupsKeepTheirOpenerInAPopupWindow() {
        #expect(route(.newPopup, features: true, gesture: false) == .popupWindow)
        #expect(route(.newPopup, features: true, gesture: true) == .popupWindow)
        #expect(route(.newWindow, features: true, gesture: false) == .popupWindow)
        #expect(route(.newPopup, opener: false) == .newTab(focus: true))
    }

    @Test func linksOpenTabsInTheOpenersPane() {
        #expect(route(.newForegroundTab) == .newTab(focus: true))
        #expect(route(.newBackgroundTab) == .newTab(focus: false))
        #expect(route(.newWindow) == .newTab(focus: true))
        #expect(route(.newWindow, features: true, gesture: true) == .newTab(focus: true))
        #expect(route(.singletonTab) == .newTab(focus: true))
        #expect(route(.unknown) == .newTab(focus: true))
    }

    @Test func currentTabAndDownloadStayInTheOpener() {
        #expect(route(.currentTab) == .loadInOpener)
        #expect(route(.saveToDisk) == .downloadInOpener)
        #expect(route(.currentTab, opener: false) == .newTab(focus: true))
        #expect(route(.saveToDisk, url: false) == .refuse)
    }

    @Test func incognitoAndIgnoredRequestsOpenNothing() {
        #expect(route(.offTheRecord) == .refuse)
        #expect(route(.ignoreAction) == .refuse)
    }

    @Test func rawDispositionsMapWithUnknownFallback() {
        #expect(ChromiumWindowOpenDisposition(raw: 4) == .newBackgroundTab)
        #expect(ChromiumWindowOpenDisposition(raw: 99) == .unknown)
        #expect(ChromiumWindowOpenDisposition(raw: Int.max) == .unknown)
    }
}

@Suite struct ChromiumEngineBridgeTests {
    @Test func processExitMapsToSadTab() {
        #expect(ChromiumPageGone(BrowserPageProcessExit(kind: .crashed, status: 11)) == ChromiumPageGone(reason: .crashed, code: 11))
        #expect(ChromiumPageGone(BrowserPageProcessExit(kind: .other)).reason == .abnormal)
        #expect(ChromiumPageGone(BrowserPageProcessExit(kind: .outOfMemory)).codeDescription == nil)
    }

    @Test func routesMapToEngineOpenPlacements() {
        #expect(ChromiumWindowOpenRoute.popupWindow.openRequestPlacement(width: 400, height: 300) == .popup(width: 400, height: 300))
        #expect(ChromiumWindowOpenRoute.newTab(focus: true).openRequestPlacement(width: nil, height: nil) == .foregroundTab)
        #expect(ChromiumWindowOpenRoute.newTab(focus: false).openRequestPlacement(width: nil, height: nil) == .backgroundTab)
        #expect(ChromiumWindowOpenRoute.loadInOpener.openRequestPlacement(width: nil, height: nil) == nil)
        #expect(ChromiumWindowOpenRoute.refuse.openRequestPlacement(width: nil, height: nil) == nil)
    }
}
