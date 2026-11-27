import Foundation
import Testing
@testable import CmuxNextBrowser

/// The Page Info windows' wire to their React pages (webviews/src/pages/site-settings, site-data, certificate).
@MainActor
struct PageInfoWireTests {
    @Test func everyWindowCommandParses() {
        #expect(PageInfoWindowCommand(wire: ["type": "setPermission", "kind": "popups", "setting": "allow"]) == .setPermission(.popups, .allow))
        #expect(PageInfoWindowCommand(wire: ["type": "resetPermissions"]) == .resetPermissions)
        #expect(PageInfoWindowCommand(wire: ["type": "deleteSiteData", "domain": "cdn.net"]) == .deleteSiteData(domain: "cdn.net"))
        #expect(PageInfoWindowCommand(wire: ["type": "deleteSiteData"]) == .deleteSiteData(domain: nil))
        #expect(PageInfoWindowCommand(wire: ["type": "exportCertificate", "index": 1]) == .exportCertificate(index: 1))
        #expect(PageInfoWindowCommand(wire: ["type": "close"]) == .close)
    }

    @Test func aWindowCommandOutsideItsChoicesIsRefused() {
        // Pop-ups never ask; USB devices are never allowed wholesale.
        #expect(PageInfoWindowCommand(wire: ["type": "setPermission", "kind": "popups", "setting": "ask"]) == nil)
        #expect(PageInfoWindowCommand(wire: ["type": "setPermission", "kind": "usb", "setting": "allow"]) == nil)
        #expect(PageInfoWindowCommand(wire: ["type": "exportCertificate", "index": -1]) == nil)
        #expect(PageInfoWindowCommand(wire: ["type": "exportCertificate"]) == nil)
        #expect(PageInfoWindowCommand(wire: ["type": "deleteSiteData", "domain": ""]) == nil)
        #expect(PageInfoWindowCommand(wire: ["type": "show", "page": ["type": "main"]]) == nil)
    }

    @Test func theSiteSettingsStateListsTheEnginesPermissionsInOrderWithTheirChoices() throws {
        let site = PageInfoSite(url: URL(string: "https://example.com/a"), kind: .web(.secure))
        let state = PageInfoWindowWire.siteSettings(
            site: site, origin: "https://example.com", supported: [.popups, .camera, .usb],
            decisions: [.camera: .block], usage: SiteDataSummary(entries: [
                SiteDataEntry(domain: "example.com", cookieCount: 3, isThirdParty: false),
                SiteDataEntry(domain: "cdn.net", cookieCount: 2, isThirdParty: true),
            ]))
        let decoded = try Self.roundTrip(state)
        #expect(decoded["origin"] as? String == "https://example.com")
        #expect((decoded["site"] as? [String: Any])?["displayName"] as? String == "example.com")
        let rows = try #require(decoded["permissions"] as? [[String: Any]])
        #expect(rows.map { $0["kind"] as? String } == ["camera", "popups", "usb"])
        #expect(rows[0]["setting"] as? String == "block" && rows[0]["isDefault"] as? Bool == false)
        #expect(rows[1]["setting"] as? String == "block" && rows[1]["isDefault"] as? Bool == true)
        #expect(rows[1]["choices"] as? [String] == ["allow", "block"])
        #expect(rows[2]["choices"] as? [String] == ["ask", "block"])
        #expect(decoded["canReset"] as? Bool == true)
        let usage = try #require(decoded["usage"] as? [String: Int])
        #expect(usage == ["firstPartyCookies": 3, "siteCount": 2])

        let loading = try Self.roundTrip(PageInfoWindowWire.siteSettings(site: site, origin: "https://example.com", supported: [],
                                                                          decisions: [.popups: .block], usage: nil))
        #expect(loading["usage"] is NSNull)
        #expect(loading["canReset"] as? Bool == false, "a decision equal to the default resets nothing")
    }

    @Test func theSiteDataStateIsEachSiteOrNullWhileLoading() throws {
        #expect(try Self.roundTrip(PageInfoWindowWire.siteData(nil))["entries"] is NSNull)
        let data = SiteDataSummary(entries: [
            SiteDataEntry(domain: "tracker.net", cookieCount: 0, hasOtherData: true, isThirdParty: true),
            SiteDataEntry(domain: "example.com", cookieCount: 4, isThirdParty: false),
        ])
        let entries = try #require(try Self.roundTrip(PageInfoWindowWire.siteData(data))["entries"] as? [[String: Any]])
        #expect(entries.map { $0["domain"] as? String } == ["example.com", "tracker.net"], "this site first")
        #expect(entries[1]["hasOtherData"] as? Bool == true && entries[1]["isThirdParty"] as? Bool == true)
        #expect(entries[0]["cookieCount"] as? Int == 4)
    }

    @Test func theCertificateStateCarriesEveryFieldFingerprintsAndPEM() throws {
        let der = try #require(Data(base64Encoded: Self.selfSignedDER))
        let certificate = try PageInfoCertificate(der: der)
        let decoded = try Self.roundTrip(PageInfoWindowWire.certificate(chain: [certificate], failure: "expired"))
        #expect(decoded["failure"] as? String == "expired")
        let chain = try #require(decoded["chain"] as? [[String: Any]])
        let leaf = try #require(chain.first)
        #expect(leaf["version"] as? Int == 3)
        #expect(leaf["serialNumber"] as? String == "12:34")
        #expect(leaf["sha256Fingerprint"] as? String == "d273e4249cf3ff0b4b480a524d37213e95249ea80f891bdbc841426deab2f5bf")
        #expect((leaf["sha1Fingerprint"] as? String)?.count == 40)
        #expect((leaf["publicKeySHA256"] as? String)?.count == 64)
        #expect((leaf["pem"] as? String)?.hasPrefix("-----BEGIN CERTIFICATE-----\n") == true)
        #expect(leaf["subjectAlternativeNames"] as? [String] == ["example.com", "www.example.com"])
        let subject = try #require(leaf["subject"] as? [String: Any])
        #expect(subject["commonName"] as? String == "example.com")
        #expect(subject["organization"] as? String == "Example Org")
        #expect(subject["organizationalUnit"] as? String == "Web")
        #expect((subject["summary"] as? String)?.contains("CN = example.com") == true)
        // 2026-11-07T01:19:57Z, in milliseconds.
        #expect(leaf["notBefore"] as? Double == 1_794_014_397_000)
        #expect(leaf["notAfter"] is Double)
        #expect(try Self.roundTrip(PageInfoWindowWire.certificate(chain: [], failure: nil))["failure"] == nil)
    }

    private static func roundTrip(_ state: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: state)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `openssl req -x509` (P-256, serial 0x1234): CN example.com, O Example Org, OU Web, SANs
    /// example.com and www.example.com.
    private static let selfSignedDER = """
        MIIB4DCCAYagAwIBAgICEjQwCgYIKoZIzj0EAwIwOjEUMBIGA1UEAwwLZXhhbXBsZS5jb20xFDASBgNVBAoMC0V4YW1wbGUgT3JnMQwwCgYDVQQLDANXZWIwHhcNMjYxMTA3MDExOTU3WhcNMzYxMTA0MDExOTU3WjA6MRQwEgYDVQQDDAtleGFtcGxlLmNvbTEUMBIGA1UECgwLRXhhbXBsZSBPcmcxDDAKBgNVBAsMA1dlYjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABFxhXPTGqQURMTWUiiMYWfVkMwWKM8lX33gUosVhGWxmiXIaLY/UWXpXO+GZu7htY1sglqgPztewPr0jbR9yW8ujfDB6MB0GA1UdDgQWBBQtwjUtoyNqei85TKIl1gxjVQZn+jAfBgNVHSMEGDAWgBQtwjUtoyNqei85TKIl1gxjVQZn+jAPBgNVHRMBAf8EBTADAQH/MCcGA1UdEQQgMB6CC2V4YW1wbGUuY29tgg93d3cuZXhhbXBsZS5jb20wCgYIKoZIzj0EAwIDSAAwRQIhAJXvHoYLPe9R9XCIalf0bc/IxNYZuzcYATC04fCLz/J/AiAUgFW804lwhXU8uD/hLBR3abCLpuVef8JIw53PIYZBbg==
        """
}

/// Reset permissions from the site settings window when the bubble's model is empty (the window
/// opened from a notice before the bubble): the engine's own decisions reset too.
@MainActor
struct SitePermissionEngineResetTests {
    @Test func anEngineDecisionTheStoreNeverHadResetsToItsDefault() async {
        let tab = MockBrowserEngine().makeMockTab(.init(initialURL: URL(string: "https://example.com")))
        tab.pageInfoFake.live = [.camera: .allow]
        await SitePermissionEngineReset.run(origin: "https://example.com", stored: [], provider: tab)
        let applied = tab.pageInfoFake.appliedChanges.map { "\($0.0)=\($0.1)@\($0.2)" }
        #expect(applied == ["camera=\(SitePermissionKind.camera.defaultSetting)@https://example.com"])
    }

    @Test func storedAndEngineKindsResetOnceEach() async {
        let tab = MockBrowserEngine().makeMockTab(.init(initialURL: URL(string: "https://example.com")))
        tab.pageInfoFake.live = [.camera: .allow, .location: .block]
        await SitePermissionEngineReset.run(origin: "https://example.com", stored: [.location, .popups], provider: tab)
        let kinds = tab.pageInfoFake.appliedChanges.map(\.0)
        #expect(Set(kinds) == [.camera, .location, .popups])
        #expect(kinds.count == 3)
        #expect(tab.pageInfoFake.appliedChanges.allSatisfy { $0.1 == $0.0.defaultSetting })
    }
}

/// A Page Info window that grows after it appears (Site data's rows arriving after its loading
/// view) stays on the screen's visible frame.
struct PageInfoWindowResizeTests {
    let visible = NSRect(x: 0, y: 40, width: 1440, height: 860)

    @Test func aWindowThatGrowsKeepsItsTopEdgeWhileThereIsRoom() {
        let frame = NSRect(x: 500, y: 600, width: 480, height: 120)
        let next = PageInfoWebWindow.resized(frame, to: CGSize(width: 480, height: 300), within: visible)
        #expect(next == NSRect(x: 500, y: 420, width: 480, height: 300))
    }

    @Test func aWindowThatWouldGrowPastTheBottomMovesUp() {
        // Centered while loading, then 640 pt of rows: its bottom would land below the Dock.
        let frame = NSRect(x: 500, y: 410, width: 480, height: 120)
        let next = PageInfoWebWindow.resized(frame, to: CGSize(width: 480, height: 640), within: visible)
        #expect(next.minY == visible.minY)
        #expect(next.height == 640)
        #expect(next.maxY <= visible.maxY)
    }

    @Test func withoutAScreenTheTopEdgeStays() {
        let frame = NSRect(x: 0, y: 100, width: 480, height: 120)
        let next = PageInfoWebWindow.resized(frame, to: CGSize(width: 480, height: 400), within: nil)
        #expect(next.maxY == frame.maxY)
    }
}
