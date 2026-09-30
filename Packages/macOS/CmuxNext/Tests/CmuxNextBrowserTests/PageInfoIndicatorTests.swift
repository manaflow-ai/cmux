import Foundation
import Testing
@testable import CmuxNextBrowser

/// URL and security state -> the omnibar's page-info button (Chrome's
/// location icon states).
@MainActor
struct PageInfoIndicatorTests {
    private func indicator(_ url: String?, _ security: BrowserSecurityState, chip: OmnibarPresentation.Chip = .page(focused: false)) -> PageInfoIndicator {
        PageInfoIndicator.resolve(site: PageInfoSite(url: url.flatMap(URL.init(string:)), security: security), chip: chip)
    }

    @Test func secureHTTPSShowsTheTuneIconWithoutText() {
        let result = indicator("https://example.com/a", .secure)
        #expect(result.symbol == "slider.horizontal.3")
        #expect(result.label == nil)
        #expect(result.tone == .neutral)
        #expect(result.isTriggerable)
    }

    @Test func plainHTTPShowsANotSecureChip() {
        let result = indicator("http://neverssl.com", .insecure)
        #expect(result.symbol == PageInfoIndicator.Symbol.notSecure)
        #expect(result.label == .notSecure)
        #expect(result.tone == .neutral)
        #expect(result.isTriggerable)
    }

    @Test func mixedContentIsNotSecureButNotRed() {
        let result = indicator("https://mixed.example", .mixedContent)
        #expect(result.label == .notSecure)
        #expect(result.tone == .neutral)
    }

    @Test func certificateErrorPageIsARedNotSecureChip() {
        var state = BrowserTabState(url: URL(string: "https://expired.badssl.com/"), security: .secure)
        state.phase = .failed(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateHasBadDate,
                                               message: "expired", failingURL: URL(string: "https://expired.badssl.com/")))
        let site = PageInfoSite(state: state)
        #expect(site.kind == .web(.certificateError(code: NSURLErrorServerCertificateHasBadDate)))
        let result = PageInfoIndicator.resolve(site: site, chip: .page(focused: false))
        #expect(result.label == .notSecure)
        #expect(result.tone == .danger)
        #expect(PageInfoSite.omnibarSecurity(for: state) == .broken)
    }

    @Test func chromiumCertificateErrorsAreRecognized() {
        #expect(PageInfoSite.isCertificateError(BrowserLoadError(domain: "net", code: -201, message: "ERR_CERT_DATE_INVALID")))
        #expect(!PageInfoSite.isCertificateError(BrowserLoadError(domain: "net", code: -105, message: "NAME_NOT_RESOLVED")))
        #expect(!PageInfoSite.isCertificateError(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, message: "")))
    }

    @Test func dangerousSitesSayDangerous() {
        let result = indicator("https://phish.example", .dangerous)
        #expect(result.label == .dangerous)
        #expect(result.tone == .danger)
    }

    @Test func localFilesInternalAndExtensionPages() {
        #expect(indicator("file:///tmp/a.html", .local).label == .file)
        #expect(indicator("file:///tmp/a.html", .local).symbol == PageInfoIndicator.Symbol.file)
        #expect(indicator("cmux://settings", .none).label == .product)
        #expect(indicator("chrome://version", .none).label == .product)
        let ext = indicator("chrome-extension://abcdef/popup.html", .none)
        #expect(ext.symbol == PageInfoIndicator.Symbol.extensionPage)
        #expect(ext.isTriggerable)
    }

    @Test func blankPagesHaveNothingToOpen() {
        #expect(!indicator("about:blank", .local).isTriggerable)
        #expect(!indicator(nil, .none).isTriggerable)
        #expect(!indicator("data:text/html,hi", .local).isTriggerable)
    }

    @Test func focusedOmniboxKeepsTheIconAndDropsTheText() {
        let result = indicator("http://neverssl.com", .insecure, chip: .page(focused: true))
        #expect(result.symbol == PageInfoIndicator.Symbol.notSecure)
        #expect(result.label == nil)
        #expect(result.isTriggerable)
    }

    @Test func userInputShowsTheInputIconAndOpensNothing() {
        let result = indicator("https://example.com", .secure, chip: .input(symbol: "globe"))
        #expect(result.symbol == "globe")
        #expect(!result.isTriggerable)
        #expect(result.label == nil)
    }

    @Test func omnibarPhasesMapToChipStates() {
        let url = URL(string: "https://example.com")!
        var state = OmnibarState(pageURL: url)
        #expect(OmnibarPresentation(state).chip == .page(focused: false))
        state.phase = .focused
        #expect(OmnibarPresentation(state).chip == .page(focused: true))
        state.phase = .editing
        #expect(OmnibarPresentation(state).chip == .input(symbol: "magnifyingglass"))
        state.phase = .idle
        state.retainedText = "typed but not committed"
        #expect(OmnibarPresentation(state).chip == .input(symbol: "magnifyingglass"))
        #expect(OmnibarPresentation(OmnibarState(pageURL: nil)).chip == .input(symbol: "magnifyingglass"))
    }

    @Test func originsAndDisplayNames() {
        let site = PageInfoSite(url: URL(string: "https://Example.com:8443/path?q=1"), security: .secure)
        #expect(site.origin == "https://example.com:8443")
        #expect(site.displayName == "Example.com:8443")
        #expect(PageInfoSite(url: URL(string: "https://example.com:443/"), security: .secure).origin == "https://example.com")
        #expect(PageInfoSite(url: URL(string: "file:///tmp/x.html"), security: .local).origin == nil)
        #expect(PageInfoSite(url: URL(string: "file:///tmp/x.html"), security: .local).displayName == "/tmp/x.html")
    }
}

/// X.509 parsing against an openssl-generated certificate.
struct PageInfoCertificateTests {
    static let der = Data(base64Encoded: "MIICGjCCAb+gAwIBAgIDChssMAoGCCqGSM49BAMCMFExCzAJBgNVBAYTAlVTMRQwEgYDVQQKDAtFeGFtcGxlIE9yZzERMA8GA1UECwwIV2ViIFRlYW0xGTAXBgNVBAMMEHd3dy5leGFtcGxlLnRlc3QwHhcNMjYwOTMwMDU0NTIyWhcNMjcwOTMwMDU0NTIyWjBRMQswCQYDVQQGEwJVUzEUMBIGA1UECgwLRXhhbXBsZSBPcmcxETAPBgNVBAsMCFdlYiBUZWFtMRkwFwYDVQQDDBB3d3cuZXhhbXBsZS50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKdFuRZFTorBWq5l2tdZ6cDIJ4XIg3cci/gKUppWaXatyNa18HsrZ8edMjq6AZg9zTCsZn1euWndIWBmp3vh/faOBhTCBgjAdBgNVHQ4EFgQU94vs8Mm26Hx7IdYR8NN9tbBQx/EwHwYDVR0jBBgwFoAU94vs8Mm26Hx7IdYR8NN9tbBQx/EwDwYDVR0TAQH/BAUwAwEB/zAvBgNVHREEKDAmghB3d3cuZXhhbXBsZS50ZXN0ggxleGFtcGxlLnRlc3SHBAoAAAEwCgYIKoZIzj0EAwIDSQAwRgIhAJk+FoFSJV3oH68q5y6cMkEgUDTXolD1Rl6/ERlkwY7FAiEAz8ptXbPLBHRQC+gMpiaKGqyLPTmiw5U1nPSTMGV/yb8=")!

    @Test func parsesNamesValidityAndFingerprints() throws {
        let certificate = try PageInfoCertificate(der: Self.der)
        #expect(certificate.version == 3)
        #expect(certificate.serialNumber == "0A:1B:2C")
        #expect(certificate.subject.commonName == "www.example.test")
        #expect(certificate.subject.organization == "Example Org")
        #expect(certificate.subject.organizationalUnit == "Web Team")
        #expect(certificate.issuer.commonName == "www.example.test")
        #expect(certificate.subjectAlternativeNames == ["www.example.test", "example.test", "10.0.0.1"])
        #expect(certificate.sha256Fingerprint == "d98e7cefd2a014d8f419abdf43f7a486c3ea9c1076ef254f454d2b52c94b4565")
        #expect(certificate.publicKeySHA256 == "61ed93b86527283f4f313c9d1a5b43caa82cf0275c1543feb3ea818d61a6c1e3")
        #expect(certificate.sha1Fingerprint == "6969011d6355fef873425116ee65682733a94527")
        #expect(certificate.publicKeyAlgorithm == "Elliptic Curve Public Key")
        #expect(certificate.signatureAlgorithm == "X9.62 ECDSA Signature with SHA-256")
        let notBefore = try #require(certificate.notBefore)
        let notAfter = try #require(certificate.notAfter)
        #expect(notAfter.timeIntervalSince(notBefore) == 365 * 86_400)
        #expect(certificate.isWithinValidity(at: notBefore.addingTimeInterval(60)))
        #expect(!certificate.isWithinValidity(at: notAfter.addingTimeInterval(60)))
        #expect(certificate.pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
    }

    @Test func truncatedInputThrows() {
        #expect(throws: (any Error).self) { try PageInfoCertificate(der: Self.der.prefix(40)) }
    }
}
