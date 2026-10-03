import Testing

@testable import CmuxBrowser

/// A secret one session typed into a tab stays masked for every other
/// session that reads that tab (`tabs.use`), which does not hold the secret.
@Suite("Browser REPL typed secrets")
struct BrowserReplTypedSecretsTests {
    private static let domains = [try! BrowserReplDomainPattern.parse("https://login.example.com", title: "test")]

    @Test func anotherSessionsReadsMaskATypedSecret() throws {
        var typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redactJSON(#"{"value":"hunter2-secret"}"#) == #"{"value":"<secret:password>"}"#)
        #expect(reader.redact("q=hunter2%2Dsecret") == "q=<secret:password>")
        let masks = typed.captureMasks(forReader: "reader")
        #expect(masks.map { $0["value"] as? String } == ["hunter2-secret"])
        #expect((masks.first?["domains"] as? [[String: Any]])?.first?["raw"] as? String == "https://login.example.com")
    }

    @Test func theTypingSessionKeepsItsOwnRedaction() {
        var typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        #expect(typed.redaction(forReader: "typist") == nil)
        #expect(typed.captureMasks(forReader: "typist").isEmpty)
    }

    @Test func aSessionThatLeftNoLongerKeepsItsTypedSecretsToItself() {
        var typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        // A later session with the same name does not hold the secret.
        typed.sessionLeft("typist")
        #expect(typed.redaction(forReader: "typist")?.redact("hunter2-secret") == "<secret:password>")
    }

    @Test func masksEndWhenTheTabCloses() {
        var typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "a", value: "first-value", domains: Self.domains, typist: "typist")
        typed.record(tab: "tab2", name: "b", value: "second-value", domains: Self.domains, typist: "typist")
        typed.tabClosed("tab1")
        let reader = typed.redaction(forReader: "reader")
        #expect(reader?.redact("first-value second-value") == "first-value <secret:b>")
        typed.tabClosed("tab2")
        #expect(typed.redaction(forReader: "reader") == nil)
    }
}
