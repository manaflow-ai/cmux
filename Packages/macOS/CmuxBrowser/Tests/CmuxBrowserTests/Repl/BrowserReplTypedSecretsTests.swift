import Testing

@testable import CmuxBrowser

/// A secret one session typed into a tab stays masked for every other
/// session that reads that tab (`tabs.use`), which does not hold the secret.
@Suite("Browser REPL typed secrets")
struct BrowserReplTypedSecretsTests {
    private static let domains = [try! BrowserReplDomainPattern.parse("https://login.example.com", title: "test")]

    @Test func anotherSessionsReadsMaskATypedSecret() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redactJSON(#"{"value":"hunter2-secret"}"#) == #"{"value":"<secret:password>"}"#)
        #expect(reader.redact("q=hunter2%2Dsecret") == "q=<secret:password>")
        let masks = typed.captureMasks(forReader: "reader")
        #expect(masks.map { $0["value"] as? String } == ["hunter2-secret"])
        #expect((masks.first?["domains"] as? [[String: Any]])?.first?["raw"] as? String == "https://login.example.com")
    }

    /// A capture takes its masks before it waits for the page; a value
    /// another session types into the tab meanwhile is not among them, so
    /// the capture must learn of it afterwards and not return its pixels.
    @Test func aValueTypedDuringACaptureIsReportedAfterIt() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "first-secret", domains: Self.domains, typist: "typist")
        let mark = typed.captureMark(forReader: "reader")
        #expect(!typed.typedSince(mark, forReader: "reader"))
        // The reader's own typing is not a value it must not see.
        try typed.record(tab: "tab1", name: "mine", value: "own-secret", domains: Self.domains, typist: "reader")
        #expect(!typed.typedSince(mark, forReader: "reader"))
        // Another session types while the capture waits for the page.
        try typed.record(tab: "tab1", name: "otp", value: "second-secret", domains: Self.domains, typist: "typist")
        #expect(typed.typedSince(mark, forReader: "reader"), "a value typed during the capture went unnoticed")
        // Typing the same name again (a new value) counts too.
        let later = typed.captureMark(forReader: "reader")
        try typed.record(tab: "tab1", name: "otp", value: "third-secret", domains: Self.domains, typist: "typist")
        #expect(typed.typedSince(later, forReader: "reader"))
        #expect(!typed.typedSince(typed.captureMark(forReader: "reader"), forReader: "reader"))
    }

    /// Forced order of a masked screenshot or PDF: the masks are taken and
    /// applied, then another session types a secret, then the pixels are
    /// taken. The masks the capture got lack that value, so a check after
    /// the capture that read them would pass; the driver's check reads the
    /// records as they are after the capture and refuses it.
    @MainActor
    @Test func aSecretTypedBetweenTheMaskAndTheCaptureRefusesIt() async throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "first-secret", domains: Self.domains, typist: "typist")
        let own = [["value": "own-secret", "domains": Self.domains.map(\.json)] as [String: Any]]
        var given: [String] = []
        var error: BrowserReplDriverError?
        do {
            _ = try await typed.capturing(forReader: "reader", sessionMasks: own) { masks in
                given = masks.compactMap { $0["value"] as? String }
                // The masks are on; another session types before the pixels.
                try typed.record(tab: "tab1", name: "otp", value: "second-secret", domains: Self.domains, typist: "typist")
                return "pixels"
            }
        } catch let caught as BrowserReplDriverError {
            error = caught
        }
        #expect(given.sorted() == ["first-secret", "own-secret"], "the capture's masks: \(given)")
        #expect(!given.contains("second-secret"), "the forced order did not put the typing after the masks")
        #expect(error?.code == "stale", "a capture whose masks lacked a value typed before its pixels returned them: \(String(describing: error))")

        // The reader's own typing meanwhile is its session's to check, and
        // with nothing typed the capture returns.
        let ownTyping = try await typed.capturing(forReader: "reader", sessionMasks: own) { _ in
            try typed.record(tab: "tab1", name: "mine", value: "own-secret", domains: Self.domains, typist: "reader")
            return "pixels"
        }
        #expect(ownTyping == "pixels")
        #expect(try await typed.capturing(forReader: "reader", sessionMasks: []) { _ in "pixels" } == "pixels")
    }

    /// r15 whole#1: a value the user typed into the sign-in sheet is
    /// masked for every session that reads the tab, the one whose agent
    /// asked for it included: the agent never holds it.
    @Test func aFilledCredentialIsMaskedForEverySessionIncludingTheAsker() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.recordCredential(tab: "tab1", field: "password", value: "hunter2-secret", domains: Self.domains)
        for reader in ["asker", "other"] {
            let store = try #require(typed.redaction(forReader: reader))
            #expect(store.redactJSON(#"{"value":"hunter2-secret"}"#) == #"{"value":"<secret:browserAuth.password>"}"#)
            #expect(typed.captureMasks(forReader: reader).map { $0["value"] as? String } == ["hunter2-secret"])
        }
        // A session that leaves does not unmask it, and an empty field is not a value.
        typed.sessionLeft("asker")
        #expect(typed.redaction(forReader: "asker") != nil)
        try typed.recordCredential(tab: "tab1", field: "otp", value: "", domains: Self.domains)
        #expect(typed.captureMasks(forReader: "asker").count == 1)
    }

    @Test func theTypingSessionKeepsItsOwnRedaction() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        #expect(typed.redaction(forReader: "typist") == nil)
        #expect(typed.captureMasks(forReader: "typist").isEmpty)
    }

    @Test func aSessionThatLeftNoLongerKeepsItsTypedSecretsToItself() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        // A later session with the same name does not hold the secret.
        typed.sessionLeft("typist")
        #expect(typed.redaction(forReader: "typist")?.redact("hunter2-secret") == "<secret:password>")
    }

    @Test func masksEndWhenTheTabCloses() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "a", value: "first-value", domains: Self.domains, typist: "typist")
        try typed.record(tab: "tab2", name: "b", value: "second-value", domains: Self.domains, typist: "typist")
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
        try typed.record(tab: "tab1", name: "acct_bu_2fa_code", value: code, domains: Self.domains, typist: "typist")
        let reader = try #require(typed.redaction(forReader: "reader"), "a typed code under a TOTP name was not masked for another session")
        #expect(reader.redact("code \(code) entered") == "code <secret:acct_bu_2fa_code> entered")
        #expect(typed.captureMasks(forReader: "reader").map { $0["value"] as? String } == [code])
    }

    /// Two sessions that each hold a secret named `password` type different
    /// values into one tab: both values stay masked for a third session.
    @Test func sameNamedSecretsOfTwoSessionsInOneTabAreBothMasked() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "first-session-value", domains: Self.domains, typist: "a")
        try typed.record(tab: "tab1", name: "password", value: "second-session-value", domains: Self.domains, typist: "b")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redact("first-session-value second-session-value") == "<secret:password> <secret:password>")
        // Each typist still sees the other's value masked, and its own not.
        #expect(typed.redaction(forReader: "a")?.redact("first-session-value second-session-value") == "first-session-value <secret:password>")
        #expect(typed.captureMasks(forReader: "reader").count == 2)
    }

    /// A session that types a secret name into a tab again (a new value)
    /// leaves the earlier value wherever the page kept it (another field,
    /// its history, a hidden copy) until the tab closes, so both values stay
    /// masked for other sessions, also after the typing session ends.
    @Test func aNameTypedAgainKeepsItsEarlierValueMasked() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "first-typed-value", domains: Self.domains, typist: "typist")
        try typed.record(tab: "tab1", name: "password", value: "second-typed-value", domains: Self.domains, typist: "typist")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redact("first-typed-value second-typed-value") == "<secret:password> <secret:password>")
        typed.sessionLeft("typist")
        let later = try #require(typed.redaction(forReader: "later"))
        #expect(later.redact("first-typed-value second-typed-value") == "<secret:password> <secret:password>")
        #expect(Set(typed.captureMasks(forReader: "later").compactMap { $0["value"] as? String }) == ["first-typed-value", "second-typed-value"])
        // Typing the same value again is still one record.
        try typed.record(tab: "tab1", name: "password", value: "second-typed-value", domains: Self.domains, typist: "next")
        #expect(typed.captureMasks(forReader: "reader").count == 2)
    }

    /// r18 entry#1: the same value typed into the same tab again, after
    /// its secret's domains changed, keeps masking on the earlier domains
    /// too. An older frame of the earlier domain may still show the value,
    /// so another session's screenshot or PDF must mask it there. Kept for
    /// sign-in sheet credentials too.
    @Test func theSameValueTypedAgainKeepsItsEarlierCaptureDomains() throws {
        let typed = BrowserReplTypedSecrets()
        let first = [try BrowserReplDomainPattern.parse("https://old.example.com", title: "test")]
        let second = [try BrowserReplDomainPattern.parse("https://new.example.com", title: "test")]
        try typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: first, typist: "typist")
        try typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: second, typist: "typist")
        try typed.recordCredential(tab: "tab1", field: "password", value: "credential-secret", domains: first)
        try typed.recordCredential(tab: "tab1", field: "password", value: "credential-secret", domains: second)
        for value in ["hunter2-secret", "credential-secret"] {
            let raws = typed.captureMasks(forReader: "reader")
                .filter { $0["value"] as? String == value }
                .flatMap { ($0["domains"] as? [[String: Any]] ?? []).compactMap { $0["raw"] as? String } }
            #expect(Set(raws) == ["https://old.example.com", "https://new.example.com"], "\(value) lost the domain it was first typed for")
        }
        // Still bounded: one record per value, not one per retype.
        try typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: second, typist: "typist")
        #expect(typed.captureMasks(forReader: "reader").count == 2)
    }

    /// One session types a secret of one name into two tabs: both values
    /// stay masked.
    @Test func sameNamedSecretsInTwoTabsAreBothMasked() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "value-in-tab-one", domains: Self.domains, typist: "a")
        try typed.record(tab: "tab2", name: "password", value: "value-in-tab-two", domains: Self.domains, typist: "a")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redact("value-in-tab-one value-in-tab-two") == "<secret:password> <secret:password>")
    }

    /// Redaction runs on every result and event; its store (whose patterns
    /// compile on creation) is built once per change of the typed values.
    @Test func theRedactionStoreIsReusedUntilTheTypedValuesChange() throws {
        let typed = BrowserReplTypedSecrets()
        try typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        let first = try #require(typed.redaction(forReader: "reader"))
        #expect(typed.redaction(forReader: "reader") === first, "the redaction store was rebuilt without a change")
        try typed.record(tab: "tab2", name: "token", value: "another-secret", domains: Self.domains, typist: "typist")
        let second = try #require(typed.redaction(forReader: "reader"))
        #expect(second !== first)
        #expect(second.redact("hunter2-secret another-secret") == "<secret:password> <secret:token>")
        typed.sessionLeft("typist")
        #expect(typed.redaction(forReader: "typist")?.redact("hunter2-secret") == "<secret:password>")
    }

    /// Every reader masks every value other sessions typed into open tabs,
    /// so the values held are bounded like a session's own secrets: past
    /// 4,096 the driver refuses to type another (it records a value before
    /// it types it), never forgets one that a tab may still show.
    @Test func typedValuesAreBoundedAndRefusedPastTheLimit() throws {
        let typed = BrowserReplTypedSecrets()
        let limit = 4096  // the documented bound
        for index in 0..<limit {
            try typed.record(tab: "tab\(index % 8)", name: "n\(index)", value: "value-\(index)", domains: Self.domains, typist: "typist")
        }
        #expect(throws: BrowserReplDriverError.self) {
            try typed.record(tab: "tab0", name: "one-more", value: "value-more", domains: Self.domains, typist: "typist")
        }
        // Typing a name into the same tab again with a new value is one more
        // value (the earlier one may still be in the page), so it is refused
        // too; the same value again is the record it already has.
        #expect(throws: BrowserReplDriverError.self) {
            try typed.record(tab: "tab0", name: "n0", value: "value-again", domains: Self.domains, typist: "typist")
        }
        try typed.record(tab: "tab0", name: "n0", value: "value-0", domains: Self.domains, typist: "typist")
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redact("value-4095 value-0 value-more") == "<secret:n4095> <secret:n0> value-more")
        // A closed tab's values go with it, which makes room.
        typed.tabClosed("tab1")
        try typed.record(tab: "tab0", name: "one-more", value: "value-more", domains: Self.domains, typist: "typist")
    }

    /// A tab the user keeps can see a session type the same secret every
    /// day; a value that a session which left typed, typed again by a later
    /// one, is one record, so it never fills the bound.
    @Test func aValueTypedAgainAfterItsSessionLeftIsOneRecord() throws {
        let typed = BrowserReplTypedSecrets()
        for index in 0..<5000 {
            try typed.record(tab: "kept", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "session-\(index)")
            typed.sessionLeft("session-\(index)")
        }
        let reader = try #require(typed.redaction(forReader: "reader"))
        #expect(reader.redact("hunter2-secret") == "<secret:password>")
    }

    /// The literal store a reader builds refuses values past the bound
    /// instead of growing without one.
    @Test func literalStoreIsBounded() throws {
        let store = BrowserReplSecretStore()
        for index in 0..<4096 {
            try store.setLiteral(key: "typed-\(index)", maskName: "n", value: "value-\(index)", domains: Self.domains)
        }
        #expect(throws: BrowserReplDriverError.self) {
            try store.setLiteral(key: "typed-more", maskName: "n", value: "value-more", domains: Self.domains)
        }
        #expect(throws: BrowserReplDriverError.self) {
            try BrowserReplSecretStore().setLiteral(key: "long", maskName: "n", value: String(repeating: "x", count: 4097), domains: Self.domains)
        }
    }
    /// A tab holds what sessions typed into it until it closes, also after
    /// the typist left: clients outside the REPL, which mask nothing, are
    /// refused such a tab (``BrowserReplTypedSecrets/holdsValues(inTab:)``).
    @Test func aTabHoldsTypedValuesUntilItCloses() throws {
        let typed = BrowserReplTypedSecrets()
        #expect(!typed.holdsValues(inTab: "tab1"))
        try typed.record(tab: "tab1", name: "password", value: "hunter2-secret", domains: Self.domains, typist: "typist")
        try typed.recordCredential(tab: "tab2", field: "password", value: "sheet-secret", domains: Self.domains)
        #expect(typed.holdsValues(inTab: "tab1"))
        #expect(typed.holdsValues(inTab: "tab2"), "a value the user typed into the sign-in sheet was not held")
        #expect(!typed.holdsValues(inTab: "tab3"))
        typed.sessionLeft("typist")
        #expect(typed.holdsValues(inTab: "tab1"), "the tab stopped holding the value when its typist left")
        typed.tabClosed("tab1")
        #expect(!typed.holdsValues(inTab: "tab1"))
        #expect(typed.holdsValues(inTab: "tab2"))
    }
}
