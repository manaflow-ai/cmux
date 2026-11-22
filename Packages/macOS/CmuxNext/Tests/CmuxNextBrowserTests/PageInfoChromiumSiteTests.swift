import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium site state through the CEF shim (ABI 3): content setting
/// values, cookie and SSL status replies, and guard kinds.
struct PageInfoChromiumSiteTests {
    @Test func contentSettingValuesMapToPageInfoSettings() {
        #expect(CEFContentSetting(.allow) == .allow)
        #expect(CEFContentSetting(.block) == .block)
        #expect(CEFContentSetting(.ask) == .ask)
        #expect(CEFContentSetting.default.siteSetting == nil)
        #expect(CEFContentSetting.sessionOnly.siteSetting == .allow)
        #expect(CEFContentSetting(rawValue: 2)?.siteSetting == .block)
    }

    @Test func cookieRepliesParseAndDomainMatch() {
        let cookies = CEFCookie.parse(#"[{"name":"a","domain":".example.com","path":"/"},{"name":"b","domain":"cdn.test"},{"bad":1}]"#)
        #expect(cookies.count == 2)
        #expect(cookies[1].path == "/")
        #expect(cookies[0].host == "example.com")
        #expect(cookies[0].matches(host: "www.example.com"))
        #expect(cookies[0].matches(host: "example.com"))
        #expect(!cookies[0].matches(host: "badexample.com"))
        // A host cookie is sent to its host only.
        #expect(cookies[1].matches(host: "cdn.test"))
        #expect(!cookies[1].matches(host: "a.cdn.test"))
        #expect(CEFCookie.parse("not json").isEmpty)
    }

    @Test func sslStatusParsesChainAndErrors() throws {
        let json = #"{"secure":true,"certStatus":4,"contentStatus":1,"sslVersion":772,"url":"https://x.test/","chain":["AAEC","AwQ="]}"#
        let status = try #require(CEFSSLStatus.parse(json))
        #expect(status.chain == [Data([0, 1, 2]), Data([3, 4])])
        #expect(status.hasCertificateError)
        #expect(status.hasMixedContent)
        // Revocation checks that could not run are not errors.
        let clean = try #require(CEFSSLStatus.parse(#"{"secure":true,"certStatus":48,"contentStatus":0,"chain":[]}"#))
        #expect(!clean.hasCertificateError)
        #expect(!clean.hasMixedContent)
    }

    @Test func replyEventDecodes() {
        let event = CEFShimEvent(kind: 18, browser: 7, request: 42, a: 3, b: 0, s1: "[]", s2: "")
        #expect(event == .reply(browser: 7, id: 42, value: 3, json: "[]"))
        #expect(event.browserID == 7)
    }

    @Test func guardKindsAreAskOrBlock() {
        for kind in [SitePermissionKind.usb, .serial, .hid, .bluetooth, .fileEditing] {
            #expect(kind.choices == [.ask, .block])
            #expect(kind.enabledSetting == .ask)
            #expect(SitePermissionState(kind: kind, setting: .ask, isDefault: true).isOn)
            #expect(!SitePermissionState(kind: kind, setting: .block, isDefault: false).isOn)
        }
        #expect(SitePermissionKind.camera.choices == [.ask, .allow, .block])
        #expect(SitePermissionKind.insecureContent.choices == [.allow, .block])
        #expect(SitePermissionKind.insecureContent.defaultSetting == .block)
        #expect(SitePermissionKind.thirdPartySignIn.defaultSetting == .allow)
    }

    @Test func setPermissionRejectsAllowForGuardKinds() {
        #expect(throws: PageInfoCommandError.self) {
            try PageInfoCommand.from(actionID: "browser.pageInfo.setPermission", arguments: ["permission": "usb", "setting": "allow"])
        }
        #expect((try? PageInfoCommand.from(actionID: "browser.pageInfo.setPermission",
                                            arguments: ["permission": "bluetooth", "setting": "block"])) == .setPermission(.bluetooth, .block))
    }
}
