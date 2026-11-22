import Foundation
import Testing
@testable import CmuxNextBrowser

/// Top-level-domain typo fixes for typed address bar text, Firefox's
/// `URIFixup` table (`example.con` loads `example.com`).
@Suite struct HostTypoFixupTests {
    /// Typed text -> the URL Enter loads, nil when nothing is fixed.
    static let table: [(input: String, expected: String?)] = [
        // Every typo of the table.
        ("example.ocm", "https://example.com"), ("example.con", "https://example.com"),
        ("example.cmo", "https://example.com"), ("example.xom", "https://example.com"),
        ("example.vom", "https://example.com"), ("example.cpm", "https://example.com"),
        ("example.com'", "https://example.com"),
        ("example.ent", "https://example.net"), ("example.ner", "https://example.net"),
        ("example.nte", "https://example.net"), ("example.met", "https://example.net"),
        ("example.rog", "https://example.org"), ("example.ogr", "https://example.org"),
        ("example.prg", "https://example.org"), ("example.orh", "https://example.org"),
        // Scheme, port, path, query and fragment stay as typed.
        ("http://example.con:8080/a/b?q=1&r=2#frag", "http://example.com:8080/a/b?q=1&r=2#frag"),
        ("https://docs.example.ner/guide", "https://docs.example.net/guide"),
        ("www.Example.CON/Path?Q=1", "https://www.Example.com/Path?Q=1"),
        ("  example.con  ", "https://example.com"),
        // Real top-level domains, explicit trailing dot, IPs, single labels.
        ("example.com", nil), ("example.co", nil), ("example.net", nil), ("example.cn", nil),
        ("example.dev", nil), ("example.con.", nil), ("example.con.au", nil), ("example.conx", nil),
        ("localhost", nil), ("localhost:3000", nil), ("con", nil), ("192.168.0.1", nil),
        ("[::1]:3000", nil), ("10.0.0.5:8080/x.con", nil),
        // Userinfo, other schemes, files, whitespace, a bad port.
        ("user@example.con", nil), ("ftp://example.con", nil), ("javascript://example.con", nil),
        ("/tmp/example.con", nil), ("~/notes.con", nil), ("go to example.con", nil),
        ("example.con:http", nil), ("", nil),
    ]

    @Test func typedTextTable() {
        for (input, expected) in Self.table {
            let fixed = OmniboxResolver().typoFixedURL(for: input)
            #expect(fixed?.url.absoluteString == expected, "\(input.debugDescription)")
        }
    }

    @Test func aRealTopLevelDomainIsNeverRewritten() {
        // If `con` were ever delegated, typing it would load it.
        #expect(HostTypoFixup.fix("example.con", isTopLevelDomain: { $0 == "con" }) == nil)
        #expect(HostTypoFixup.fix("example.con", isTopLevelDomain: { _ in false })?.text == "example.com")
        // The bundled IANA list knows real ones and none of the typos.
        for label in ["com", "net", "org", "dev", "app", "io", "co", "cn", "xn--p1ai", "COM"] {
            #expect(TopLevelDomains.contains(label), "\(label)")
        }
        for typo in HostTypoFixup.typos.keys {
            #expect(!TopLevelDomains.contains(typo), "\(typo) became a real top-level domain")
        }
    }

    // MARK: Omnibar

    private func committed(_ sim: OmnibarSim) -> URL? {
        guard case .commit(let url)? = sim.ended.last else { return nil }
        return url
    }

    private func sim(chromium: Bool = false) -> OmnibarSim {
        let sim = OmnibarSim()
        sim.historyURLs = []
        sim.resolver.urlResolver.allowsChromiumSchemes = chromium
        return sim
    }

    /// The same fix in WebKit and Chromium tabs (one omnibar reducer).
    @Test(arguments: [false, true]) func enterFixesTypedText(chromium: Bool) {
        let sim = sim(chromium: chromium)
        sim.focus()
        sim.type("example.con/a?b=c#d")
        sim.key(.enter(.currentTab))
        let fixed = URL(string: "https://example.com/a?b=c#d")!
        #expect(committed(sim) == fixed)
        #expect(sim.effects.contains(.typedNavigation(fixed)))
        #expect(sim.effects.contains(.hostTypoFixed(typedHost: "example.con")))
    }

    @Test func enterFixesAnApostropheThatWouldSearch() {
        let sim = sim()
        sim.focus()
        sim.type("example.com'")
        sim.key(.enter(.currentTab))
        #expect(committed(sim) == URL(string: "https://example.com")!)
    }

    @Test func newTabAndWindowDispositionsLoadTheFixToo() {
        let sim = sim()
        sim.focus()
        sim.type("example.rog")
        sim.key(.enter(.newBackgroundTab))
        #expect(sim.ended == [.open(URL(string: "https://example.org")!, .newBackgroundTab)])
    }

    @Test func pastedTextLoadsAsPasted() {
        let pasted = sim()
        pasted.focus()
        pasted.paste("example.con")
        pasted.key(.enter(.currentTab))
        #expect(committed(pasted) == URL(string: "https://example.con")!)
        // A paste followed by typing is still pasted text.
        let edited = sim()
        edited.focus()
        edited.paste("example.co")
        edited.type("n")
        edited.key(.enter(.currentTab))
        #expect(committed(edited) == URL(string: "https://example.con")!)
        // Paste and Go never fixes.
        let go = sim()
        go.send(.pasteAndGo("example.con"))
        #expect(committed(go) == URL(string: "https://example.con")!)
    }

    @Test func clearingAPasteThenTypingFixes() {
        let sim = sim()
        sim.focus()
        sim.paste("something")
        for _ in 0..<"something".count { sim.backspace() }
        sim.type("example.con")
        sim.key(.enter(.currentTab))
        #expect(committed(sim) == URL(string: "https://example.com")!)
    }

    @Test func historyRowsLoadAsStored() throws {
        let kept = URL(string: "https://example.con/kept")!
        // Enter on a history page's inline completion.
        let inline = sim()
        inline.historyURLs = [kept.absoluteString]
        inline.focus()
        inline.type("example.con")
        #expect(!inline.state.edit.inlineCompletion.isEmpty)
        inline.key(.enter(.currentTab))
        #expect(committed(inline) == kept)
        // An arrowed row loads its own URL.
        let arrowed = sim()
        arrowed.historyURLs = [kept.absoluteString]
        arrowed.focus()
        arrowed.type("example.con")
        arrowed.key(.down)
        let selected = try #require(arrowed.state.popup.selected)
        let row = arrowed.state.popup.rows[selected].url
        arrowed.key(.enter(.currentTab))
        #expect(committed(arrowed) == row)
        #expect(row.host() == "example.con")
    }

    /// Typing the original host again after a fix (for example after
    /// leaving the fixed page at once) loads it as typed.
    @Test func typingTheSameHostAgainIsNotFixedAgain() {
        let sim = sim()
        sim.focus()
        sim.type("example.con")
        sim.key(.enter(.currentTab))
        #expect(committed(sim) == URL(string: "https://example.com")!)
        sim.send(.pageURLChanged(URL(string: "https://example.com")!))
        sim.focus()
        sim.type("example.con/again")
        sim.key(.enter(.currentTab))
        #expect(committed(sim) == URL(string: "https://example.con/again")!)
        // Another host still gets its fix.
        sim.focus()
        sim.type("other.con")
        sim.key(.enter(.currentTab))
        #expect(committed(sim) == URL(string: "https://other.com")!)
    }
}
