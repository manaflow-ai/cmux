import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Cookie counts and deletion through fake stores, DevTools result
/// parsing, and the registry command contract.
@MainActor
struct PageInfoSiteDataTests {
    private func makeTab() -> MockBrowserTab {
        MockBrowserTab(configuration: BrowserTabConfiguration(), engineKind: .webkit, completesNavigationsImmediately: true)
    }

    @Test func registrableDomains() {
        #expect(SiteDomain.registrable(".cdn.example.com") == "example.com")
        #expect(SiteDomain.registrable("www.bbc.co.uk") == "bbc.co.uk")
        #expect(SiteDomain.registrable("user.github.io") == "user.github.io")
        #expect(SiteDomain.registrable("localhost") == "localhost")
        #expect(SiteDomain.registrable("10.0.0.1") == "10.0.0.1")
    }

    @Test func cookieCountsSplitFirstAndThirdParty() async {
        let tab = makeTab()
        tab.pageInfoFake.cookieDomains = ["example.com", ".example.com", "www.example.com", ".doubleclick.net", "ads.doubleclick.net", ".cdn.fonts.test"]
        tab.pageInfoFake.otherDataDomains = ["example.com", "storage.widgets.test"]
        let summary = await tab.pageInfoSiteData(pageHost: "www.example.com")
        #expect(summary.firstPartyCookies == 3)
        #expect(summary.thirdPartySites.map(\.domain) == ["doubleclick.net", "fonts.test", "widgets.test"])
        #expect(summary.thirdPartySites.first?.cookieCount == 2)
        #expect(summary.thirdPartySites.last?.hasOtherData == true)
        #expect(summary.siteCount == 4)
        #expect(summary.entries.first?.domain == "example.com")
    }

    @Test func deletingASiteRemovesItsCookiesOnly() async {
        let tab = makeTab()
        tab.pageInfoFake.cookieDomains = ["example.com", ".doubleclick.net"]
        await tab.pageInfoDeleteSiteData(domains: ["doubleclick.net"])
        let summary = await tab.pageInfoSiteData(pageHost: "example.com")
        #expect(summary.entries.map(\.domain) == ["example.com"])
    }

    @Test func devToolsParsing() {
        #expect(CEFPageInfoParsing.certificates(#"{"tableNames":["AAEC","AwQ="]}"#) == [Data([0, 1, 2]), Data([3, 4])])
        let tree = #"{"frameTree":{"frame":{"url":"https://a.test/"},"resources":[{"url":"https://cdn.b.test/x.js"},{"url":"data:image/png;base64,"},{"url":"https://a.test/y.css"}],"childFrames":[{"frame":{"url":"https://c.test:8443/f"},"resources":[]}]}}"#
        #expect(CEFPageInfoParsing.resourceOrigins(tree) == ["https://a.test", "https://cdn.b.test", "https://c.test:8443"])
    }

    @Test func commandsRoundTripThroughRegistryArguments() throws {
        let commands: [PageInfoCommand] = [
            .show(.main), .show(.security), .show(.cookies), .showCertificate, .setPermission(.camera, .block),
            .resetPermissions, .siteSettings, .manageSiteData, .deleteSiteData(domain: "x.test"), .deleteSiteData(domain: nil),
            .aboutThisPage,
        ]
        for command in commands {
            let action = try #require(command.action)
            #expect(try PageInfoCommand.from(actionID: action.id, arguments: action.arguments) == command)
        }
        #expect(PageInfoCommand.show(.permission(.camera)).action == nil)
        #expect(throws: PageInfoCommandError.invalidArgument(name: "setting", value: "ask")) {
            try PageInfoCommand.from(actionID: PageInfoCommand.ActionID.setPermission, arguments: ["permission": "sound", "setting": "ask"])
        }
        #expect(throws: PageInfoCommandError.invalidArgument(name: "permission", value: "teleport")) {
            try PageInfoCommand.from(actionID: PageInfoCommand.ActionID.setPermission, arguments: ["permission": "teleport", "setting": "allow"])
        }
    }

    @Test func controllerWritesTheStoreAndTellsTheEngine() async throws {
        let tab = makeTab()
        tab.load(URL(string: "https://permission.site/")!)
        let controller = PageInfoController(tab: { tab }, anchor: { nil })
        try controller.run(.setPermission(.camera, .block))
        let store = tab.sitePermissions
        #expect(store.setting(.camera, for: "https://permission.site") == .block)
        #expect(tab.pageInfoActivity.changedSinceLoad == [.camera])
        await Task.yield()
        for _ in 0 ..< 10 where tab.pageInfoFake.appliedChanges.isEmpty { await Task.yield() }
        #expect(tab.pageInfoFake.appliedChanges.first?.1 == .block)

        controller.refreshPermissions()
        #expect(controller.model.permissions.map(\.kind) == [.camera])
        try controller.run(.resetPermissions)
        #expect(store.decisions["https://permission.site"] == nil)
    }

    @Test func blankAndLocalPagesRefuseSiteCommands() {
        let blank = makeTab()
        let controller = PageInfoController(tab: { blank }, anchor: { nil })
        #expect(throws: PageInfoCommandError.noSiteInformation) { try controller.run(.show(.main)) }
        let file = makeTab()
        file.load(URL(filePath: "/tmp/page.html"))
        let fileController = PageInfoController(tab: { file }, anchor: { nil })
        #expect(throws: PageInfoCommandError.notAWebPage) { try fileController.run(.setPermission(.camera, .allow)) }
    }
}

/// Reset permissions in a Site settings window for an origin the tab has
/// left must reset the engine too: Chromium keeps its own persisted
/// exceptions, so clearing only the shared store left a granted
/// permission active.
@MainActor
struct SiteSettingsResetTests {
    @Test func resetForAnotherOriginResetsTheEngine() async throws {
        let tab = MockBrowserTab(configuration: BrowserTabConfiguration(), engineKind: .cef, completesNavigationsImmediately: true)
        let origin = "https://camera.example"
        let store = tab.sitePermissions
        await store.whenLoaded()
        store.set(.allow, .camera, for: origin)
        store.set(.allow, .microphone, for: origin)
        let window = SiteSettingsWindow(origin: origin, site: PageInfoSite(url: URL(string: origin), security: .secure), store: store,
                                        provider: tab, send: { _ in })
        window.perform(NSSelectorFromString("resetPermissions"))
        for _ in 0..<200 where tab.pageInfoFake.appliedChanges.count < 2 { await Task.yield() }
        let applied = tab.pageInfoFake.appliedChanges.map { "\($0.0.rawValue)=\($0.1.rawValue)@\($0.2)" }.sorted()
        #expect(applied == ["camera=ask@\(origin)", "microphone=ask@\(origin)"])
        #expect(store.decisions[origin] == nil)
        window.close()
    }
}
