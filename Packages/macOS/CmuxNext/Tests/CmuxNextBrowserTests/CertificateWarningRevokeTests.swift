import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Turning certificate warnings on again (Chrome's Page Info "Turn on
/// warnings", Safari): after the user proceeds past an untrusted
/// certificate, Page Info says so and can forget that choice for the host
/// in that profile, and the reload shows the warning again.
@MainActor
@Suite(.serialized)
struct CertificateWarningRevokeTests {
    private let host = "self-signed.test"
    private var page: URL { URL(string: "https://\(host)/")! }

    @Test func theCommandIsARegistryAction() throws {
        let command = PageInfoCommand.reenableCertificateWarnings
        let action = try #require(command.action)
        #expect(action.id == "browser.pageInfo.reenableCertificateWarnings")
        #expect(action.arguments.isEmpty)
        #expect(try PageInfoCommand.from(actionID: action.id, arguments: [:]) == command)
        #expect(PageInfoCommand.actionIDs.contains(action.id), "the App binds every Page Info action id")
    }

    /// WebKit forgets the choice for that host in that profile only; the
    /// next server-trust challenge for the host fails again, which shows
    /// the interstitial.
    @Test func webKitForgetsOnlyThatHostInThatProfile() {
        let engine = WebKitEngine()
        let work = BrowserProfileID(rawValue: UUID())
        engine.certificateExceptions = [.default: [host, "other.test"], work: [host]]
        #expect(engine.hasCertificateException(host, profile: .default))

        #expect(engine.forgetCertificateException(host: host, profile: .default))
        #expect(!engine.hasCertificateException(host, profile: .default))
        #expect(engine.hasCertificateException("other.test", profile: .default), "other hosts keep their exception")
        #expect(engine.certificateExceptions[work] == [host], "other profiles keep their exception")
        #expect(!engine.forgetCertificateException(host: host, profile: .default), "nothing left to forget")
        let trust = NSURLAuthenticationMethodServerTrust
        #expect(WebKitTab.decide(method: trust, failures: 0, trusted: false, excepted: engine.hasCertificateException(host, profile: .default))
            == .defaultHandling)
    }

    /// Live finding (nxbp15-v1): after the warnings are turned on again,
    /// WebKit reloads over the kept-alive connection the old exception
    /// trusted, gets no new challenge, and showed the page. The host's next
    /// committed page is verified again until it passes or the user
    /// proceeds once more.
    @Test func turningWarningsOnAgainVerifiesTheNextPageOfThatHost() {
        let engine = WebKitEngine()
        let work = BrowserProfileID(rawValue: UUID())
        engine.allowCertificateException(host: host, profile: .default)
        engine.allowCertificateException(host: host, profile: work)
        #expect(!engine.needsCertificateRecheck(host, profile: .default), "an excepted host is not rechecked")

        engine.forgetCertificateException(host: host, profile: .default)
        #expect(engine.needsCertificateRecheck(host, profile: .default))
        #expect(!engine.needsCertificateRecheck(host, profile: work), "only the profile whose warnings were turned on")
        #expect(!engine.needsCertificateRecheck("other.test", profile: .default))

        engine.allowCertificateException(host: host, profile: .default)
        #expect(!engine.needsCertificateRecheck(host, profile: .default), "Proceed again ends the recheck")
        #expect(engine.hasCertificateException(host, profile: .default))
    }

    /// A WebKit page loaded past an untrusted certificate is "Not secure",
    /// as in Chrome; it showed "Connection is secure".
    @Test func aWebKitPageLoadedPastAWarningIsNotSecure() {
        #expect(BrowserTabStateMachine.security(for: page, hasOnlySecureContent: true, certificateBypassed: true) == .broken)
        #expect(BrowserTabStateMachine.security(for: page, hasOnlySecureContent: false, certificateBypassed: true) == .broken)
        #expect(BrowserTabStateMachine.security(for: page, hasOnlySecureContent: true, certificateBypassed: false) == .secure)
        #expect(BrowserTabStateMachine.security(for: page, hasOnlySecureContent: false, certificateBypassed: false) == .mixedContent)
        let plain = URL(string: "http://\(host)/")!
        #expect(BrowserTabStateMachine.security(for: plain, hasOnlySecureContent: false, certificateBypassed: true) == .insecure)
    }

    /// Page Info shows the bypass, the action turns the warnings on and
    /// reloads, and a site with warnings on refuses the action.
    @Test func pageInfoShowsTheBypassAndTurnsWarningsOnAgain() async throws {
        let tab = MockBrowserTab(configuration: BrowserTabConfiguration(), engineKind: .webkit, completesNavigationsImmediately: true)
        tab.load(page)
        tab.pageInfoFake.certificateWarningsOff = true
        let controller = PageInfoController(tab: { tab }, anchor: { nil })
        controller.refreshPermissions()
        #expect(controller.model.certificateWarningsOff)

        try controller.run(.reenableCertificateWarnings)
        for _ in 0 ..< 50 where tab.pageInfoFake.certificateWarningsOff { await Task.yield() }
        #expect(!tab.pageInfoFake.certificateWarningsOff)
        #expect(tab.commands.last == .reload, "the reload shows the warning again")

        controller.refreshPermissions()
        #expect(!controller.model.certificateWarningsOff)
        #expect(throws: PageInfoCommandError.certificateWarningsAlreadyOn) { try controller.run(.reenableCertificateWarnings) }
    }

    /// The security page offers "Turn on warnings" only for a bypassed
    /// site, and the row sends the registry command.
    @Test func theSecurityPageOffersTurnOnWarnings() throws {
        let model = PageInfoModel()
        model.site = PageInfoSite(url: page, security: .broken)
        model.page = .security
        model.certificates = []
        var sent: [PageInfoCommand] = []
        let plain = PageInfoPages(model: model, send: { sent.append($0) }).build()
        #expect(Self.find("pageInfo.turnOnWarnings", in: plain) == nil)

        model.certificateWarningsOff = true
        let view = PageInfoPages(model: model, send: { sent.append($0) }).build()
        let row = try #require(Self.find("pageInfo.turnOnWarnings", in: view) as? PageInfoRowView)
        row.onActivate?()
        #expect(sent == [.reenableCertificateWarnings])
    }

    /// Chromium: a committed https page whose SSL status has a certificate
    /// error (security `.broken`) was loaded past the warning.
    @Test func aChromiumPageLoadedPastAWarningHasWarningsOff() async {
        let runtime = CEFRuntime.shared
        let paneHost = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "cert-revoke"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: paneHost, runtime: runtime)
        paneHost.add(tab)
        tab.machine.apply(.urlChanged(page))
        #expect(!tab.certificateWarningsTurnedOff)
        tab.machine.apply(.securityChanged(.broken))
        #expect(tab.certificateWarningsTurnedOff)
        tab.machine.apply(.urlChanged(URL(string: "http://\(host)/")!))
        tab.machine.apply(.securityChanged(.broken))
        #expect(!tab.certificateWarningsTurnedOff, "plain http has no certificate to bypass")
        // No page and no shim here: nothing is cleared and nothing reloads.
        #expect(await tab.turnOnCertificateWarnings() == false)
    }

    private static func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews { if let hit = find(identifier, in: child) { return hit } }
        return nil
    }
}
