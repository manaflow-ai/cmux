import CmuxTextMatching
import Darwin
import Testing

@Suite struct TmuxGlobPatternTests {
    @Test(arguments: [
        ("*", "", true),
        ("*", "anything at all", true),
        ("a*c", "abbbc", true),
        ("a*c", "abbbd", false),
        ("a?c", "abc", true),
        ("a?c", "ac", false),
        ("?", "", false),
        ("[a-c]x", "bx", true),
        ("[a-c]x", "dx", false),
        ("[!a-c]x", "dx", true),
        ("[!a-c]x", "bx", false),
        ("[^a-c]x", "dx", true),
        ("[^a-c]x", "ax", false),
        ("[]]", "]", true),
        ("[!]]", "]", false),
        ("[a-]", "-", true),
        ("\\*", "*", true),
        ("\\*", "x", false),
        ("\\?", "?", true),
        ("a[", "a[", false), // an unterminated bracket is an error to fnmatch, so nothing matches
        ("a\\", "a\\", false), // so is a trailing backslash
        ("[[:digit:]]*", "42 lines", true),
        ("[[:digit:]]*", "lines", false),
        ("*/*", "a/b", true), // no FNM_PATHNAME: * crosses slashes
        ("*", ".hidden", true), // no FNM_PERIOD
        ("ABC", "abc", false),
    ])
    func matchesWhole(pattern: String, text: String, expected: Bool) {
        #expect(TmuxGlobPattern(pattern, caseInsensitive: false).matchesWhole(text) == expected)
    }

    @Test func caseFold() {
        #expect(TmuxGlobPattern("ABC", caseInsensitive: true).matchesWhole("abc"))
        #expect(TmuxGlobPattern("[A-C]", caseInsensitive: true).matchesWhole("b"))
        #expect(!TmuxGlobPattern("[a-c]", caseInsensitive: false).matchesWhole("B"))
    }

    /// tmux find-window wraps the string as `*s*`, so a glob finds a substring.
    @Test func firstMatchFindsTheSubstring() throws {
        let line = "error: disk full on /dev/sda1"
        let pattern = TmuxGlobPattern("disk*full", caseInsensitive: false)
        let range = try #require(pattern.firstMatch(in: line))
        #expect(line[range] == "disk full")
        #expect(TmuxGlobPattern("sd?1", caseInsensitive: false).firstMatch(in: line).map { String(line[$0]) } == "sda1")
        #expect(TmuxGlobPattern("nope", caseInsensitive: false).firstMatch(in: line) == nil)
    }

    @Test func firstMatchIsLeftmostThenShortest() throws {
        let line = "abXabYab"
        let range = try #require(TmuxGlobPattern("a*b", caseInsensitive: false).firstMatch(in: line))
        #expect(line.distance(from: line.startIndex, to: range.lowerBound) == 0)
        #expect(line[range] == "ab")
    }

    @Test func firstMatchHandlesNonASCII() throws {
        let line = "café ☕ ready"
        let range = try #require(TmuxGlobPattern("☕ r?ady", caseInsensitive: false).firstMatch(in: line))
        #expect(line[range] == "☕ ready")
    }

    /// The glob must agree with the platform's fnmatch(3), which is what tmux calls.
    @Test(arguments: [false, true])
    func agreesWithDarwinFnmatch(caseInsensitive: Bool) {
        var generator = DeterministicGenerator(seed: 0x5EED_F00D)
        // Each pattern piece comes with texts that may or may not satisfy it, so about
        // half the generated pairs are built to come close to matching.
        let pieces: [(pattern: String, samples: [String])] = [
            ("a", ["a", "A"]), ("b", ["b"]), ("C", ["C", "c"]), ("-", ["-"]), ("/", ["/"]), (".", ["."]),
            ("*", ["", "ab", "/x", "]["]), ("?", ["x", "/", "."]), ("[ab]", ["a", "b", "B"]), ("[!a]", ["b", "a"]),
            ("[^b]", ["a", "b"]), ("[a-c]", ["b", "B", "d"]), ("[A-C]", ["B", "b"]), ("[]a]", ["]", "a"]),
            ("[a-]", ["-", "a"]), ("\\*", ["*", "x"]), ("\\a", ["a"]), ("[[:digit:]]", ["1", "x"]),
            ("[[:upper:]]", ["A", "a"]), ("[[:alpha:]]", ["q", "1"]), ("[", ["["]), ("\\", ["\\"]), ("]", ["]"]),
            ("[[.a.]]", ["a"]), ("[a\\-c]", ["-", "b"]), ("[z-a]", ["m"]), ("1", ["1"]), ("[!]-a]", ["^", "b"]),
        ]
        let noise = ["a", "b", "c", "A", "B", "C", "-", "/", ".", "*", "?", "[", "]", "\\", "1", "x", ""]
        var checked = 0
        var positives = 0
        for _ in 0..<1_000 {
            let chosen = (0..<generator.next(upTo: 4) + 1).map { _ in pieces[generator.next(upTo: pieces.count)] }
            let pattern = chosen.map(\.pattern).joined()
            let text: String
            if generator.next(upTo: 2) == 0 {
                text = chosen.map { $0.samples[generator.next(upTo: $0.samples.count)] }.joined()
            } else {
                text = (0..<generator.next(upTo: 5)).map { _ in noise[generator.next(upTo: noise.count)] }.joined()
            }
            let expected = fnmatch(pattern, text, caseInsensitive ? FNM_CASEFOLD : 0) == 0
            let actual = TmuxGlobPattern(pattern, caseInsensitive: caseInsensitive).matchesWhole(text)
            #expect(actual == expected, "pattern \(pattern) text \(text)")
            checked += 1
            if expected { positives += 1 }
        }
        #expect(checked == 1_000)
        // The generated set must exercise matches, not only rejections.
        #expect(positives >= 200, "only \(positives) generated pairs match")
    }
}

/// A small xorshift generator so the differential cases are the same on every run.
private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(upTo bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}
