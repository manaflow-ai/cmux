import Testing

@testable import CmuxBrowser

/// A secret one session typed into a tab stays masked for every other
/// session that reads that tab (`tabs.use`), which does not hold the secret.
@Suite("Browser REPL typed secrets")
struct BrowserReplTypedSecretsTests {
    private static let domains = [try! BrowserReplDomainPattern.parse("https://login.example.com", title: "test")]

    @Test func anotherSessionsReadsMaskATypedSecret() throws {
        let typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redactJSON(#"{"value":"hunter2-secret"}"#) == #"{"value":"<secret:password>"}"#)
        #expect(reader.redact("q=hunter2%2Dsecret") == "q=<secret:password>")
        let masks = typed.captureMasks(forReader: "reader")
        #expect(masks.map { $0["value"] as? String } == ["hunter2-secret"])
        #expect((masks.first?["domains"] as? [[String: Any]])?.first?["raw"] as? String == "https://login.example.com")
    }

    @Test func theTypingSessionKeepsItsOwnRedaction() {
        let typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        #expect(typed.redaction(forReader: "typist") == nil)
        #expect(typed.captureMasks(forReader: "typist").isEmpty)
    }

    @Test func aSessionThatLeftNoLongerKeepsItsTypedSecretsToItself() {
        let typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        // A later session with the same name does not hold the secret.
        typed.sessionLeft("typist")
        #expect(typed.redaction(forReader: "typist")?.redact("hunter2-secret") == "<secret:password>")
    }

    @Test func masksEndWhenTheTabCloses() {
        let typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "a", value: "first-value", domains: Self.domains, typist: "typist")
        typed.record(tab: "tab2", name: "b", value: "second-value", domains: Self.domains, typist: "typist")
        typed.tabClosed("tab1")
        let reader = typed.redaction(forReader: "reader")
        #expect(reader?.redact("first-value second-value") == "first-value <secret:b>")
        typed.tabClosed("tab2")
        #expect(typed.redaction(forReader: "reader") == nil)
    }

    /// A typed value is what the field holds: a TOTP secret's typed value
    /// is its current code, not a seed. A name that ends in `bu_2fa_code`
    /// (reference C's TOTP naming) must not turn the typed code into a seed
    /// that is dropped (not base32) or masks other numbers (base32 digits).
    @Test(arguments: ["123456", "234567"])
    func aTypedCodeUnderATOTPNameIsMaskedAsTyped(code: String) throws {
        let typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "acct_bu_2fa_code", value: code, domains: Self.domains, typist: "typist")
        let reader = try #require(typed.redaction(forReader: "reader"), "a typed code under a TOTP name was not masked for another session")
        #expect(reader.redact("code \(code) entered") == "code <secret:acct_bu_2fa_code> entered")
        #expect(typed.captureMasks(forReader: "reader").map { $0["value"] as? String } == [code])
    }

    /// Two sessions that each hold a secret named `password` type different
    /// values into one tab: both values stay masked for a third session.
    @Test func sameNamedSecretsOfTwoSessionsInOneTabAreBothMasked() throws {
        let typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "first-session-value", domains: Self.domains, typist: "a")
        typed.record(tab: "tab1", name: "password", value: "second-session-value", domains: Self.domains, typist: "b")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redact("first-session-value second-session-value") == "<secret:password> <secret:password>")
        // Each typist still sees the other's value masked, and its own not.
        #expect(typed.redaction(forReader: "a")?.redact("first-session-value second-session-value") == "first-session-value <secret:password>")
        #expect(typed.captureMasks(forReader: "reader").count == 2)
    }

    /// One session types a secret of one name into two tabs: both values
    /// stay masked.
    @Test func sameNamedSecretsInTwoTabsAreBothMasked() throws {
        let typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "value-in-tab-one", domains: Self.domains, typist: "a")
        typed.record(tab: "tab2", name: "password", value: "value-in-tab-two", domains: Self.domains, typist: "a")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redact("value-in-tab-one value-in-tab-two") == "<secret:password> <secret:password>")
    }

    /// Redaction runs on every result and event; its store (whose patterns
    /// compile on creation) is built once per change of the typed values.
    @Test func theRedactionStoreIsReusedUntilTheTypedValuesChange() throws {
        let typed = BrowserReplTypedSecrets()
        typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        let first = try #require(typed.redaction(forReader: "reader"))
        #expect(typed.redaction(forReader: "reader") === first, "the redaction store was rebuilt without a change")
        typed.record(tab: "tab2", name: "token", value: "another-secret", domains: Self.domains, typist: "typist")
        let second = try #require(typed.redaction(forReader: "reader"))
        #expect(second !== first)
        #expect(second.redact("hunter2-secret another-secret") == "<secret:password> <secret:token>")
        typed.sessionLeft("typist")
        #expect(typed.redaction(forReader: "typist")?.redact("hunter2-secret") == "<secret:password>")
    }
}
