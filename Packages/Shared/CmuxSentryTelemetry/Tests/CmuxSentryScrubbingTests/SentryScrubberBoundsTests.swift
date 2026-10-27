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

    @Test func aLongerStringIsCutBackToTheWordBeforeTheCap() {
        let text = String(repeating: "word ", count: 3000)
        let output = scrubber.scrub(text)
        #expect(output.hasSuffix("word" + marker))
        // 8192 = 5 * 1638 + 2: the cut is inside a word, so that word and the space before it go.
        #expect(output.unicodeScalars.count == 5 * 1638 - 1 + marker.unicodeScalars.count)
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
        #expect(output == filler + marker)
        #expect(!output.contains("sk-"))
    }

    @Test func theCapCountsUnicodeScalars() {
        // Each "é" is two scalars (e + U+0301) but one Character: the cap must not read past it in Characters.
        let accented = String(repeating: "e\u{301}", count: SentryScrubber.maxScrubbedScalars)
        let output = scrubber.scrub(accented + " end")
        #expect(output == marker)
    }

    @Test func aStringOfOneHugeWordKeepsOnlyTheMarker() {
        #expect(scrubber.scrub(String(repeating: "Z", count: 64 << 10)) == marker)
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

    @Test func aJWTAfterAHyphenIsRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(scrubber.scrub("x-\(jwt) y") == "x-<redacted-secret> y")
    }
}
