@testable import CmuxNextMobileHost
import CmuxNextBrowser
import CmuxNextMobile
import Foundation
import Testing

@MainActor
struct MobileSiteDataExporterTests {
    let url = "https://example.com/app"

    func page() -> MockBrowserTab {
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        page.load(URL(string: url)!)
        page.evaluationResult = .object([
            "url": .string(url), "origin": .string("https://example.com"),
            "items": .array([.array([.string("theme"), .string("dark")])]),
        ])
        return page
    }

    var request: MobileHostSiteDataRequest {
        .init(request: 1, surface: 2, site: "example.com", url: url)
    }

    func makeExporter(page: MockBrowserTab, incognito: Bool, agentsProfile: Bool,
                      isCurrent: @escaping () -> Bool, readCookies: @escaping () async throws -> [BrowserCookie],
                      afterEvaluation: @escaping () -> Void = {}) throws -> MobileSiteDataExporter {
        let model = NSObject()
        return try MobileSiteDataExporter(model: model, currentModel: { isCurrent() ? model : nil },
            page: { _ in page }, identity: { $0 },
            snapshot: { _, page in .init(profileID: page.profileID.rawValue, incognito: incognito, agentsProfile: agentsProfile,
                url: page.state.url?.absoluteString, navigation: page.state.activeNavigation?.rawValue, isLoading: page.state.isLoading) },
            readCookies: { _ in try await readCookies() },
            evaluate: { page, script, world, gesture in
                #expect(world == .isolated)
                #expect(gesture == .cmux)
                let result = try await page.evaluate(script, world: world, gesture: gesture)
                afterEvaluation()
                return result
            })
    }

    @Test func privateProfilesNeverReadTheStore() async throws {
        for (incognito, agents) in [(true, false), (false, true)] {
            var read = false
            let exporter = try makeExporter(page: page(), incognito: incognito, agentsProfile: agents,
                isCurrent: { true }, readCookies: { read = true; return [] })
            await #expect(throws: MobileSiteDataExportError.privateProfile) { try await exporter.read(request) }
            #expect(!read)
        }
    }

    @Test func sameURLReloadDuringCookieReadDiscardsTheExport() async throws {
        let page = page()
        let exporter = try makeExporter(page: page, incognito: false, agentsProfile: false,
            isCurrent: { true }, readCookies: { page.reload(); return [] })
        await #expect(throws: MobileSiteDataExportError.pageChanged) { try await exporter.read(request) }
    }

    @Test func replacedPageCannotReturnCookies() async throws {
        var current = true
        let exporter = try makeExporter(page: page(), incognito: false, agentsProfile: false,
            isCurrent: { current }, readCookies: { current = false; return [] })
        await #expect(throws: MobileSiteDataExportError.pageChanged) { try await exporter.read(request) }
    }

    @Test func replacementEngineForTheSameModelDiscardsTheExport() async throws {
        let model = NSObject()
        var currentPage = page()
        let original = currentPage
        let exporter = try MobileSiteDataExporter(model: model, currentModel: { model },
            page: { _ in currentPage }, identity: { $0 },
            snapshot: { _, page in .init(profileID: page.profileID.rawValue, incognito: false, agentsProfile: false,
                url: page.state.url?.absoluteString, navigation: page.state.activeNavigation?.rawValue, isLoading: page.state.isLoading) },
            readCookies: { _ in currentPage = self.page(); return [] },
            evaluate: { try await $0.evaluate($1, world: $2, gesture: $3) })
        await #expect(throws: MobileSiteDataExportError.pageChanged) { try await exporter.read(request) }
        #expect(currentPage !== original)
    }

    @Test func sameURLReloadDuringStorageReadDiscardsTheExport() async throws {
        let page = page()
        let exporter = try makeExporter(page: page, incognito: false, agentsProfile: false,
            isCurrent: { true }, readCookies: { [] }, afterEvaluation: { page.reload() })
        await #expect(throws: MobileSiteDataExportError.pageChanged) { try await exporter.read(request) }
    }

    @Test func exportsSessionCookieAttributesAndStorage() async throws {
        let cookie = BrowserCookie(name: "session", value: "private", domain: ".example.com", path: "/",
            expires: nil, secure: true, httpOnly: true, sameSite: "Strict")
        let exporter = try makeExporter(page: page(), incognito: false, agentsProfile: false,
            isCurrent: { true }, readCookies: { [cookie] })
        let result = try await exporter.read(request)
        #expect(result.cookies.count == 1)
        #expect(result.cookies.first?.sameSite == "strict")
        #expect(result.cookies.first?.expiresMS == nil)
        #expect(result.cookies.first?.httpOnly == true)
        #expect(result.localStorage.first?.items == [["theme", "dark"]])
    }

    @Test func unrelatedProfileCookiesNeverEnterTheControlLine() async throws {
        let cookies = [".example.com", "sub.example.com", "notexample.com", "example.com.other.test"].map {
            BrowserCookie(name: "session", value: "private", domain: $0, path: "/",
                expires: nil, secure: true, httpOnly: true)
        }
        let exporter = try makeExporter(page: page(), incognito: false, agentsProfile: false,
            isCurrent: { true }, readCookies: { cookies })
        let result = try await exporter.read(request)
        #expect(result.cookies.map(\.domain) == [".example.com", "sub.example.com"])
    }

    @Test func mismatchedScriptURLDiscardsTheExport() async throws {
        let page = page()
        page.evaluationResult = .object(["url": .string("https://other.test/"),
            "origin": .string("https://other.test"), "items": .array([])])
        let exporter = try makeExporter(page: page, incognito: false, agentsProfile: false,
            isCurrent: { true }, readCookies: { [] })
        await #expect(throws: MobileSiteDataExportError.unavailable) { try await exporter.read(request) }
    }
}
