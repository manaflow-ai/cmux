import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowserImport
import Foundation
import Testing

/// `cmux browser import-cookies` (`browser.importCookies`): which cookies
/// `--domain` keeps, which source profile `--from` names, and which runs must
/// ask the person (and give a reason) before anything is read.
@Suite struct CookieImportCommandTests {
    private static func cookie(_ domain: String) -> ImportedCookie {
        ImportedCookie(name: "session", value: "secret-value", domain: domain)
    }

    @Test func domainFilterKeepsTheSitesThatWouldSendTheCookie() {
        let filter = CookieDomainFilter("github.com, https://App.Linear.app/team")
        #expect(filter.domains == ["github.com", "app.linear.app"])
        #expect(filter.keeps(Self.cookie(".github.com")))
        #expect(filter.keeps(Self.cookie("github.com")))
        #expect(filter.keeps(Self.cookie("gist.github.com")), "a subdomain of a named site")
        #expect(filter.keeps(Self.cookie(".linear.app")), "a parent domain cookie the named host receives")
        #expect(!filter.keeps(Self.cookie("linear.app")), "a host-only parent cookie is not sent to a subdomain")
        #expect(!filter.keeps(Self.cookie(".notgithub.com")))
        #expect(!filter.keeps(Self.cookie("example.com")))
    }

    @Test func emptyDomainFilterKeepsEveryCookie() {
        let filter = CookieDomainFilter(" , ")
        #expect(filter.keepsAll)
        #expect(filter.keeps(Self.cookie("anything.example")))
    }

    @Test func importedCookieNeverPrintsItsValue() {
        let text = "\(Self.cookie(".github.com"))"
        #expect(!text.contains("secret-value"))
    }

    private static func profile(_ browser: String, _ directory: String, _ name: String) -> BrowserSourceProfile {
        BrowserSourceProfile(browser: ImportBrowser(rawValue: browser), directoryName: directory, displayName: name,
                             path: URL(fileURLWithPath: "/tmp/\(browser)/\(directory)"), availability: [.cookies: .available])
    }

    private static var sources: [BrowserSource] {
        [
            BrowserSource(browser: ImportBrowser(rawValue: "chrome"), appURL: nil,
                          profiles: [profile("chrome", "Profile 1", "Work"), profile("chrome", "Default", "Personal")]),
            BrowserSource(browser: ImportBrowser(rawValue: "firefox"), appURL: nil,
                          profiles: [profile("firefox", "Profiles/abcd.default-release", "default-release")]),
        ]
    }

    @Test func fromNamesABrowserAndOptionalProfile() throws {
        #expect(try CookieSourceQuery("chrome").resolve(in: Self.sources).directoryName == "Default", "no profile is Default")
        #expect(try CookieSourceQuery("Google Chrome:work").resolve(in: Self.sources).directoryName == "Profile 1",
                "the app's name and the profile's shown name, any case")
        #expect(try CookieSourceQuery("chrome:Profile 1").resolve(in: Self.sources).displayName == "Work")
        #expect(try CookieSourceQuery("firefox:default-release").resolve(in: Self.sources).browser.rawValue == "firefox")
    }

    @Test func fromRefusesWhatThisMacDoesNotHave() {
        #expect(throws: CookieSourceQuery.Failure.empty) { try CookieSourceQuery("  ") }
        #expect(throws: CookieSourceQuery.Failure.unknownBrowser("opera", known: ["chrome", "firefox"])) {
            try CookieSourceQuery("opera").resolve(in: Self.sources)
        }
        #expect(throws: CookieSourceQuery.Failure.unknownProfile(browser: "chrome", profile: "School", known: ["Work", "Personal"])) {
            try CookieSourceQuery("chrome:School").resolve(in: Self.sources)
        }
    }

    @Test func onlyAPersonsRunInTheAppSkipsTheConsentPanel() {
        #expect(!CookieImportService.needsConsent(ActionInvocation(origin: .user)))
        for origin in [ActionOrigin.cli, .mcp, .script, .remote, .page] {
            #expect(CookieImportService.needsConsent(ActionInvocation(origin: origin)), "\(origin) asks first")
        }
    }

    @Test func agentsMustGiveAReason() {
        #expect(!CookieImportService.needsReason(ActionInvocation(origin: .user)))
        #expect(!CookieImportService.needsReason(ActionInvocation(origin: .cli)), "a person typing at a terminal")
        var agentAtCLI = ActionInvocation(origin: .cli)
        agentAtCLI.callerAgentSession = "01a15270"
        #expect(CookieImportService.needsReason(agentAtCLI))
        #expect(CookieImportService.needsReason(ActionInvocation(origin: .mcp)))
        #expect(CookieImportService.needsReason(ActionInvocation(origin: .script)), "an agent's shell tool has no terminal")
    }
}
