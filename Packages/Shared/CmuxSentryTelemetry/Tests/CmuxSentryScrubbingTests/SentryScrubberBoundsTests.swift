import Foundation
import Testing

@testable import CmuxSentryScrubbing

/// What the input bounds of p10-stability-191 keep: the length cap, the PEM pairing and the
/// rewritten patterns redact what the unbounded ones did.
@Suite struct SentryScrubberBoundsTests {
    private let scrubber = SentryScrubber(homeDirectory: "/Users/dev")
    private let marker = SentryScrubber.truncatedMarker

    // MARK: - Length cap

    @Test func aStringAtTheCapIsUnchanged() {
        let text = String(repeating: "word ", count: SentryScrubber.maxScrubbedScalars / 5)
            + String(repeating: "x", count: SentryScrubber.maxScrubbedScalars % 5)
        #expect(text.unicodeScalars.count == SentryScrubber.maxScrubbedScalars)
        #expect(scrubber.scrub(text) == text)
    }

    @Test func aLongerStringIsCutHardAtTheCap() {
        let text = String(repeating: "word ", count: 3000)
        let output = scrubber.scrub(text)
        #expect(output == String(text.prefix(SentryScrubber.maxScrubbedScalars)) + marker)
    }

    @Test func aCutAtWhiteSpaceKeepsTheWholeHead() {
        let head = String(repeating: "abcd ", count: SentryScrubber.maxScrubbedScalars / 5)
            + String(repeating: "x", count: SentryScrubber.maxScrubbedScalars % 5)
        let output = scrubber.scrub(head + " tail")
        #expect(output == head + marker)
    }

    @Test func aSecretTheCapSplitsDoesNotSurvive() {
        let filler = String(repeating: "x", count: SentryScrubber.maxScrubbedScalars - 12)
        let key = "sk-" + String(repeating: "A1b2", count: 10)
        let output = scrubber.scrub(filler + " " + key + " after")
        #expect(output.hasPrefix(filler + " <redacted"))
        #expect(output.hasSuffix(marker))
        #expect(!output.contains("sk-"))
    }

    @Test func aSpacedCardNumberTheCapSplitsIsRedactedWhole() {
        // The cap falls inside the card's last group: cutting back to white space kept "4111 1111 1111".
        let filler = String(repeating: "x", count: SentryScrubber.maxScrubbedScalars - 17)
        let output = scrubber.scrub(filler + " 4111 1111 1111 1111 tail")
        #expect(output.hasPrefix(filler + " "))
        #expect(!output.contains("1111"), "card digits leaked: \(output.suffix(40))")
    }

    @Test func aSecretCutShortWhereTheReadEndsNeverReachesTheOutput() {
        // Each 60-character key shrinks to one marker, so what is read is shorter than the cap after
        // the rules: the URL the read cuts before its `@` must still not be kept.
        let keys = String(repeating: "sk-" + String(repeating: "k", count: 57) + " ", count: 100)
        let readEnd = SentryScrubber.maxScrubbedScalars + SentryScrubber.capOverscanScalars
        let pad = String(repeating: "w", count: readEnd - keys.unicodeScalars.count - 16)
        let text = keys + pad + " https://user:hunter2@host/x" + String(repeating: " more", count: 100)
        let output = scrubber.scrub(text)
        #expect(output.hasSuffix(marker))
        #expect(!output.contains("user:hu"), "cut-short credential leaked: \(output.suffix(40))")
        #expect(!output.contains("sk-"))
    }

    @Test func theCapCountsUnicodeScalars() {
        // Each "é" is two scalars (e + U+0301) but one Character: the cap must not read past it in Characters.
        let accented = String(repeating: "e\u{301}", count: SentryScrubber.maxScrubbedScalars)
        let output = scrubber.scrub(accented + " end")
        #expect(output == String(repeating: "e\u{301}", count: SentryScrubber.maxScrubbedScalars / 2) + marker)
    }

    @Test func aStringOfOneHugeWordKeepsItsHead() {
        #expect(scrubber.scrub(String(repeating: "Z", count: 64 << 10))
            == String(repeating: "Z", count: SentryScrubber.maxScrubbedScalars) + marker)
    }

    @Test func aLongMinifiedJSONMessageKeepsItsHead() {
        let json = "{" + (0..<2000).map { #""k\#($0)":\#($0)"# }.joined(separator: ",") + "}"
        #expect(json.unicodeScalars.count > SentryScrubber.maxScrubbedScalars + SentryScrubber.capOverscanScalars)
        let output = scrubber.scrub("upload failed: " + json)
        #expect(output.hasPrefix(#"upload failed: {"k0":0,"k1":1,"#))
        #expect(output.unicodeScalars.count == SentryScrubber.maxScrubbedScalars + marker.unicodeScalars.count)
    }

    // MARK: - PEM blocks

    @Test func aPEMHeaderWithNoFooterIsRedactedToTheEnd() {
        let input = "key -----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAsecretbody\nmore"
        #expect(scrubber.scrub(input) == "key <redacted-secret>")
    }

    @Test func twoPEMBlocksKeepTheTextBetweenThem() {
        let block = "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEI\n-----END EC PRIVATE KEY-----"
        #expect(scrubber.scrub("a \(block) b \(block) c") == "a <redacted-secret> b <redacted-secret> c")
    }

    @Test func aPEMHeaderAfterAnAssignmentIsStillRedactedWhole() {
        // The key=value rule used to eat "-----BEGIN" first and leave the body for no rule to match.
        let input = "key=-----BEGIN RSA PRIVATE KEY-----\nMIIEbody\n-----END RSA PRIVATE KEY----- done"
        let output = scrubber.scrub(input)
        #expect(!output.contains("MIIEbody"), "PEM body leaked: \(output)")
    }

    @Test func manyHeadersWithNoFooterAreOneRedaction() {
        let input = "x " + String(repeating: "-----BEGIN RSA PRIVATE KEY-----\n", count: 200)
        #expect(scrubber.scrub(input) == "x <redacted-secret>")
    }

    // MARK: - Rewritten patterns redact as before

    @Test func aMarkerAfterALongIdentifierRunStillRedactsItsValue() {
        let prefix = String(repeating: "x", count: 300)
        #expect(scrubber.scrub("\(prefix)token=abc123") == "\(prefix)token=<redacted-secret>")
        #expect(scrubber.scrub("\(prefix)secret: \"a&b\"") == "\(prefix)secret: \"<redacted-secret>\"")
    }

    @Test func anEmailRightAfterAnotherIsRedacted() {
        // The second address starts inside the first one's character run, where the last match ended.
        #expect(scrubber.scrub("a@b.cc1x@d.ee") == "<redacted-email><redacted-email>")
    }

    @Test func anEmailWithALongLocalPartIsRedactedWhole() {
        let local = String(repeating: "n", count: 100)
        #expect(scrubber.scrub("to \(local)@example.com now") == "to <redacted-email> now")
    }

    @Test func aURLAfterALongWordKeepsTheWordAndRedactsTheCredentials() {
        let word = String(repeating: "q", count: 60)
        #expect(
            scrubber.scrub("\(word)https://u:p@host/x")
                == "\(word)https://<redacted-secret>@host/x"
        )
    }

    @Test func aJWSWithAKilobyteHeaderIsRedactedWhole() {
        // An x5c header runs to kilobytes: the header has no length cap.
        let header = "eyJ" + String(repeating: "MIIBx5c_", count: 160) + "-tail"
        let jws = header + ".eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(header.count > 1024)
        #expect(scrubber.scrub("receipt \(jws) ok") == "receipt <redacted-secret> ok")
    }

    @Test func aJWTAfterAHyphenIsRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(scrubber.scrub("x-\(jwt) y") == "x-<redacted-secret> y")
    }
}
