import Foundation
import Testing
@testable import CmuxEgress

@Suite(.serialized)
struct CmuxEgressTests {
    @Test func listedLocalAndUnlistedHosts() {
        #expect(CmuxEgress.verdict("https://accounts.google.com/o/oauth2") == .listed)
        #expect(CmuxEgress.verdict("https://acme.atlassian.net") == .listed)
        #expect(CmuxEgress.verdict("http://localhost:3000") == .local)
        #expect(CmuxEgress.verdict("10.0.0.5") == .local)
        #expect(CmuxEgress.verdict("[::1]:80") == .local)
        #expect(CmuxEgress.verdict("tracker.example.org") == .unlisted)
    }

    @Test func namedHostsPass() {
        #expect(CmuxEgress.verdict("git.my-company.dev") == .unlisted)
        CmuxEgress.allowNamed("https://git.my-company.dev:8443/x")
        #expect(CmuxEgress.verdict("git.my-company.dev") == .named)
    }

    @Test func hostParsing() {
        #expect(CmuxEgress.hostOf("https://User@Example.ORG.:8080/a?b#c") == "example.org")
        #expect(CmuxEgress.hostOf("[::1]:9") == "::1")
    }

    @Test func enforceRefusesAndLogOnlyReports() throws {
        CmuxEgress.setMode(.enforce)
        defer { CmuxEgress.setMode(nil) }
        #expect(throws: CmuxEgress.Refused.self) { try CmuxEgress.check("https://nope.example.org", site: "test") }
        CmuxEgress.setMode(.log)
        try CmuxEgress.check("https://nope.example.org", site: "test")
        CmuxEgress.setMode(.off)
        try CmuxEgress.check("https://nope2.example.org", site: "test")
    }

    @Test func gatedSessionFailsAnUnlistedHost() async {
        CmuxEgress.setMode(.enforce)
        defer { CmuxEgress.setMode(nil) }
        let session = CmuxEgress.session(site: "test")
        do {
            _ = try await session.data(from: URL(string: "https://nope.example.org/x")!)
            Issue.record("the gate let an unlisted host through")
        } catch {
            #expect((error as? URLError)?.code == .cannotConnectToHost)
        }
    }
}
