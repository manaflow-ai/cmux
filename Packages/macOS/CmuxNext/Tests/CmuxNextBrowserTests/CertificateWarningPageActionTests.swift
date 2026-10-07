import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The certificate warning page's Proceed and Go Back without the mouse:
/// `browser.certificateWarning.proceed` / `.goBack` run the buttons' path
/// (the buttons route through the registry when the App installed a
/// router), and are enabled only while the warning page shows.
@MainActor
@Suite(.serialized)
struct CertificateWarningPageActionTests {
    private let first = URL(string: "https://first.test/")!
    private let page = URL(string: "https://self-signed.test/")!

    private func tab(_ engine: BrowserEngineKind = .webkit) -> MockBrowserTab {
        MockBrowserTab(configuration: BrowserTabConfiguration(), engineKind: engine, completesNavigationsImmediately: true)
    }

    /// The tab shows the warning page for `page`.
    private func showWarning(on tab: MockBrowserTab) {
        let id = tab.makeNavigationID()
        tab.simulate(.started(id, url: page))
        tab.simulate(.failed(id, BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                                                  message: "untrusted", failingURL: page)))
    }

    @Test func theCommandsAreRegistryActions() {
        #expect(CertificateWarningCommand.proceed.actionID == "browser.certificateWarning.proceed")
        #expect(CertificateWarningCommand.goBack.actionID == "browser.certificateWarning.goBack")
        for command in CertificateWarningCommand.allCases {
            #expect(CertificateWarningCommand(actionID: command.actionID) == command)
        }
        #expect(CertificateWarningCommand(actionID: "browserBack") == nil)
    }

    @Test func theCommandsAreEnabledOnlyWhileTheWarningPageShows() {
        let tab = tab()
        tab.load(first)
        for command in CertificateWarningCommand.allCases {
            #expect(command.unavailableReason(on: tab) == Strings.certificateWarningNotShown, "\(command)")
        }
        showWarning(on: tab)
        for command in CertificateWarningCommand.allCases {
            #expect(command.unavailableReason(on: tab) == nil, "\(command)")
        }
        #expect(CertificateWarningCommand.proceed.unavailableReason(on: nil) == Strings.certificateWarningNotShown)
    }

    @Test func proceedLoadsThePagePastTheWarning() {
        let tab = tab()
        tab.load(first)
        showWarning(on: tab)
        CertificateWarningCommand.proceed.perform(on: tab)
        #expect(tab.pageInfoFake.certificateProceeds == [page])
        #expect(tab.commands.last == .load(page))
    }

    @Test func goBackReturnsToThePreviousPageOrABlankPage() throws {
        let tab = tab()
        tab.load(first)
        tab.load(page)
        showWarning(on: tab)
        CertificateWarningCommand.goBack.perform(on: tab)
        #expect(tab.commands.last == .goBack)

        let alone = self.tab()
        showWarning(on: alone)
        CertificateWarningCommand.goBack.perform(on: alone)
        #expect(alone.commands.last == .load(try #require(URL(string: BrowserNewTabPage.blankURL))),
                "the warning was the first page: nowhere to go back to")
    }

    /// A click on a button runs the registry action when the App routes it,
    /// so the click and the action take one path; without a router the
    /// button runs the command itself.
    @Test func theButtonsRouteThroughTheRegistry() {
        let tab = tab()
        tab.load(first)
        showWarning(on: tab)
        let views = PageStatusViews()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let content = NSView(frame: parent.bounds)
        parent.addSubview(content)
        views.install(in: parent, over: content) { tab }
        views.render(tab.state)
        var routed: [CertificateWarningCommand] = []
        views.certificateWarningRouter = { routed.append($0); return true }
        views.errorView.onProceed?()
        views.errorView.onBack?()
        #expect(routed == [.proceed, .goBack])
        #expect(tab.pageInfoFake.certificateProceeds.isEmpty, "the registry ran it, not the button")

        views.certificateWarningRouter = nil
        views.errorView.onProceed?()
        #expect(tab.pageInfoFake.certificateProceeds == [page])
    }

    /// Chromium shows its own interstitial; cmux's commands say where its
    /// buttons are.
    @Test func chromiumPointsToItsOwnWarningPage() {
        let tab = tab(.cef)
        tab.load(page)
        for command in CertificateWarningCommand.allCases {
            #expect(command.unavailableReason(on: tab) == Strings.certificateWarningChromium, "\(command)")
        }
    }
}
