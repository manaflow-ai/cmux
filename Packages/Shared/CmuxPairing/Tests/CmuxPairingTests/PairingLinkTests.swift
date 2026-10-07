import CmuxPairing
import Foundation
import Testing

@Suite struct PairingLinkTests {
    let now = Date(timeIntervalSince1970: 1_799_999_000)
    let code = String(repeating: "0", count: 25) + "Z"
    let key = String(repeating: "A", count: 43)

    func link(_ query: String, path: String = "pair/1", scheme: String = "cmux") -> URL {
        URL(string: "\(scheme)://\(path)?\(query)")!
    }

    var query: String { "o=\(code)&h=host_a1&t=team_a1&k=\(key)&e=1800000000&n=Bea's%20Mac%2BPro" }

    @Test func parsesTheBackendLink() throws {
        let parsed = try PairingLink(url: link(query), now: now)
        guard case .pair(let offer) = parsed.kind else { Issue.record("not a pair link"); return }
        #expect(offer.code == code)
        #expect(offer.host == "host_a1")
        #expect(offer.team == "team_a1")
        #expect(offer.hostKey == key)
        #expect(offer.name == "Bea's Mac+Pro")
        #expect(offer.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func roundTripsThroughTheCanonicalURL() throws {
        let parsed = try PairingLink(url: link(query), now: now)
        let again = try PairingLink(url: parsed.url, now: now)
        #expect(again == parsed)
        #expect(parsed.url.absoluteString.hasPrefix("cmux://pair/1?o="))
        #expect(!parsed.url.absoluteString.contains("+"))
    }

    @Test func acceptsWebAndBundleSchemes() throws {
        let web = try PairingLink(url: URL(string: "https://cmux.com/app/pair/1?\(query)")!, now: now)
        let www = try PairingLink(url: URL(string: "https://www.cmux.com/app/pair/1?\(query)")!, now: now)
        let bundle = try PairingLink(url: link(query, scheme: "cmux-ios-dev.cmux.ios.nx6"), now: now)
        #expect(web == www)
        #expect(web == bundle)
        #expect(throws: PairingLinkError.notPairingLink) { try PairingLink(url: URL(string: "https://evil.example/app/pair/1?\(query)")!, now: now) }
        #expect(throws: PairingLinkError.notPairingLink) { try PairingLink(url: link(query, path: "feed/1"), now: now) }
    }

    @Test func refusesOtherVersionsAndBadFields() {
        #expect(throws: PairingLinkError.unsupportedVersion("2")) { try PairingLink(url: link(query, path: "pair/2"), now: now) }
        #expect(throws: PairingLinkError.missingField("version")) { try PairingLink(url: link(query, path: "pair"), now: now) }
        #expect(throws: PairingLinkError.missingField("o")) { try PairingLink(url: link("h=host_a1&t=team_a1&k=\(key)&e=1800000000&n=x"), now: now) }
        #expect(throws: PairingLinkError.invalidField("o")) { try PairingLink(url: link(query.replacingOccurrences(of: code, with: "I" + code.dropFirst())), now: now) }
        #expect(throws: PairingLinkError.invalidField("k")) { try PairingLink(url: link(query.replacingOccurrences(of: key, with: "short")), now: now) }
        #expect(throws: PairingLinkError.invalidField("h")) { try PairingLink(url: link(query.replacingOccurrences(of: "host_a1", with: "mac")), now: now) }
        #expect(throws: PairingLinkError.invalidField("e")) { try PairingLink(url: link(query.replacingOccurrences(of: "e=1800000000", with: "e=soon")), now: now) }
        #expect(throws: PairingLinkError.expired) { try PairingLink(url: link(query), now: Date(timeIntervalSince1970: 1_800_000_001)) }
    }

    @Test func ignoresUnknownKeysWithinAVersion() throws {
        _ = try PairingLink(url: link(query + "&future=1"), now: now)
    }

    @Test func parsesAttach() throws {
        let parsed = try PairingLink(url: link("h=host_a1&t=team_a1", path: "attach/1"), now: now)
        #expect(parsed.kind == .attach(host: "host_a1", team: "team_a1"))
        #expect(try PairingLink(url: parsed.url, now: now) == parsed)
    }
}
