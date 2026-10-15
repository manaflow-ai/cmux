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
        }
    }

    @Test func emptyChromiumPageGetsCmuxSentenceAndErrorName() {
        let notFound = ChromiumNetError(code: -105, text: "net::ERR_NAME_NOT_RESOLVED")
        #expect(notFound.name == "ERR_NAME_NOT_RESOLVED")
        guard case .cmuxPage(let message) = notFound.presentation(chromiumShowsPage: false) else {
            Issue.record("expected cmux page")
            return
        }
        #expect(message.hasSuffix("\nERR_NAME_NOT_RESOLVED"))
        #expect(message.hasPrefix(notFound.sentence))

        let certificate = ChromiumNetError(code: -202, text: "net::ERR_CERT_AUTHORITY_INVALID")
        #expect(certificate.isCertificateError)
        #expect(certificate.message == "\(certificate.sentence) (ERR_CERT_AUTHORITY_INVALID)")
    }

    @Test func sentencesDifferByFailureKind() {
        let sentences = Set([-105, -102, -118, -106, -200, -2].map { ChromiumNetError(code: $0, text: "").sentence })
        #expect(sentences.count == 6)
        #expect(ChromiumNetError(code: -137, text: "").sentence == ChromiumNetError(code: -105, text: "").sentence)
        #expect(ChromiumNetError(code: -7, text: "").sentence == ChromiumNetError(code: -118, text: "").sentence)
    }

    @Test func missingTextFallsBackToTheCode() {
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
        #expect(ChromiumPageGone(reason: .abnormal, code: nil).errorCodeLine == nil)
    }

    @Test func usesChromesWording() {
        #expect(ChromiumPageGone.title == "Aw, Snap!")
        #expect(ChromiumPageGone.message == "Something went wrong while displaying this webpage.")
        #expect(ChromiumPageGone(reason: .crashed, code: 11).errorCodeLine == "Error code: SIGSEGV")
    }
}

@Suite struct ChromiumKeyWindowRuleTests {
    typealias Rule = ChromiumKeyWindowRule

    @Test func unclickedPageWindowGivesTheKeysBack() {
        #expect(Rule.decide(.init(parent: .thisWindow, isChromiumPage: true)) == .unchosenPage)
        #expect(Rule.decide(.init(parent: .thisWindow, isChromiumPage: true, clicked: true, overPane: false))
            == .unchosenPage)
    }

    @Test func clickIntoPlacedPageChoosesIt() {
        #expect(Rule.decide(.init(parent: .thisWindow, isChromiumPage: true, clicked: true, overPane: true))
            == .chosenPage)
    }

    @Test func devToolsKeepTheKeys() {
        #expect(Rule.decide(.init(parent: .thisWindow, isChromiumPage: true, isDevTools: true)) == .devTools)
    }

    @Test func otherOwnedWindowOverPaneReapplies() {
        #expect(Rule.decide(.init(parent: .thisWindow, isChromiumPage: false, overPane: true)) == .reapply)
        #expect(Rule.decide(.init(parent: .thisWindow, isChromiumPage: false)) == .ignore)
    }

    @Test func parentlessPageBelongsOnlyToTheActiveWindow() {
        #expect(Rule.decide(.init(parent: .none, isChromiumPage: true)) == .unchosenPage)
        #expect(Rule.decide(.init(parent: .none, isChromiumPage: true, thisWindowIsActive: false)) == .ignore)
        #expect(Rule.shouldReclaim(.init(parent: .none, isChromiumPage: true)))
        #expect(!Rule.shouldReclaim(.init(parent: .none, isChromiumPage: true, thisWindowIsActive: false)))
        #expect(!Rule.shouldReclaim(.init(parent: .none, isChromiumPage: false)))
    }

    @Test func panelsAndOtherWindowsAreIgnored() {
        #expect(Rule.decide(.init(parent: .thisWindow, isPanel: true, isChromiumPage: true)) == .ignore)
        #expect(Rule.decide(.init(parent: .other, isChromiumPage: true, clicked: true, overPane: true)) == .ignore)
        #expect(!Rule.shouldReclaim(.init(parent: .other, isChromiumPage: true)))
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
