import CmuxFuzzSupport
import CmuxNextCompat
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Terminal links from program output: the rows a program wrapped a URL over,
/// the text Ghostty hands over to open (OSC 8 or link detection), and the link filter's cache of
/// file checks. Any output keeps each contract and never traps. Seeded property tests on
/// CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS); the URL pieces follow Chromium's
/// url_parse_fuzzer (url/url_parse_fuzzer.cc). Nonisolated: only the opened-URL property needs the
/// main actor (TerminalSurfaceView).
nonisolated struct TerminalLinkFuzzTests {
    /// Pieces of program output: URL parts, prose, frames, wide and combining characters.
    static let rowPieces: [String] = [
        "https://", "http://", "https:/", "ht", "h", "example.com", "/", "?", "=", "&", "%20", "#", "a", "Z", "0",
        "-", "_", ".", ",", ")", "(", "'", "\"", " ", "  ", "│", "─", "╭", "⎿", "▌", "中", "🙂", "⚠️", "e\u{301}",
        "\r\n", "\n", "\t", "\u{0}", "\u{200B}",
    ]
    static let urlPieces: [String] = [
        "http", "https", "file", "HTTP", "javascript", "ftp", ":", "//", "/", "user:pw@", "@", "localhost", "example.com",
        "host", ":8080", ":0", "?q=1", "#frag", "%00", "%0a", "%E2%80%AE", "%", "%zz", " ", "\t", "\n", "\u{202E}",
        "\u{200B}", "\u{FEFF}", "\u{AD}", "\u{2066}", "\u{E0041}", "%F3%A0%81%81", "\u{0085}", "[::1]", "é", "🙂", "..", "~",
    ]

    static func joined(_ pieces: [String], _ rng: inout FuzzRNG, _ limit: Int) -> String {
        var out = ""
        for _ in 0..<rng.below(limit) { out += rng.element(of: pieces) ?? "" }
        return out
    }

    /// One input of a property its first choice picks, replayed from bytes: the two properties that
    /// need no view (``openURL(_:)`` needs the main actor and AppKit). Darwin only for now:
    /// CmuxNextTerminal imports AppKit, so the Linux libFuzzer targets skip this
    /// suite unless they build TerminalWrappedLink.swift, which needs only Foundation, on its own.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        if rng.bool() {
            try wrappedLink(&rng)
        } else {
            try linkFilter(&rng)
        }
    }

    // MARK: - Wrapped links

    /// A link joined over rows is two or more segments, top to bottom, inside the rows given,
    /// one cell per URL character, one of them under the pointer; its text is an `http(s)` URL.
    static func wrappedLink(_ rng: inout FuzzRNG) throws {
        var rows: [String] = []
        for _ in 0..<(1 + rng.below(8)) { rows.append(joined(rowPieces, &rng, 12)) }
        let columns = rng.int(in: -2...60)
        let firstRow = rng.int(in: -3...100)
        let row = firstRow + rng.int(in: -1...rows.count)
        let column = rng.int(in: -2...(max(columns, 0) + 2))
        let hint: String? = switch rng.below(3) {
        case 0: nil
        case 1: joined(rowPieces, &rng, 6)
        default: String(rows.joined().prefix(rng.below(80)).suffix(rng.below(80)))
        }
        guard let link = TerminalWrappedLink.find(rows: rows, firstRow: firstRow, columns: columns, column: column,
                                                  row: row, hint: hint) else { return }
        let where_ = "\(link) at (\(column), \(row)) in \(rows.debugDescription), \(columns) columns"
        try FuzzRun.check(link.segments.count > 1, "one segment: \(where_)")
        try FuzzRun.check(link.text.hasPrefix("http://") || link.text.hasPrefix("https://"), "not a web URL: \(where_)")
        try FuzzRun.check(link.text.allSatisfy { TerminalWrappedLink.isLinkCharacter($0) }, "not URL characters: \(where_)")
        try FuzzRun.check(zip(link.segments, link.segments.dropFirst()).allSatisfy { pair in pair.0.row < pair.1.row },
                          "rows out of order: \(where_)")
        try FuzzRun.check(link.segments.allSatisfy { $0.start >= 0 && $0.start <= $0.end && (firstRow..<(firstRow + rows.count)).contains($0.row) },
                          "a segment outside the rows: \(where_)")
        try FuzzRun.check(link.segments.reduce(0) { $0 + $1.end - $1.start + 1 } == link.text.count, "cells are not the text: \(where_)")
        try FuzzRun.check(link.segments.contains { $0.row == row && $0.start <= column && column <= $0.end },
                          "no segment under the pointer: \(where_)")
    }

    // MARK: - Opened URLs

    /// What a delegate-free terminal opens: an `http(s)` URL with a host and no credentials, or a
    /// local `file` URL, never one with control or invisible format characters (Unicode Cc and Cf,
    /// raw or percent-encoded: bidi overrides, zero-width marks, tag characters).
    @MainActor static func openURL(_ rng: inout FuzzRNG) throws {
        let text = joined(urlPieces, &rng, 10)
        guard let url = TerminalSurfaceView.url(from: text) else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        let shown = "\(text.debugDescription) opened \(url.absoluteString.debugDescription)"
        try FuzzRun.check(["http", "https", "file"].contains(scheme), "scheme: \(shown)")
        try FuzzRun.check(url.user == nil && url.password == nil, "credentials: \(shown)")
        if scheme == "file" {
            try FuzzRun.check(url.port == nil && url.query == nil && url.fragment == nil, "file URL parts: \(shown)")
            try FuzzRun.check([nil, "", "localhost"].contains(url.host?.lowercased()), "remote file host: \(shown)")
        } else {
            try FuzzRun.check(url.host?.isEmpty == false, "no host: \(shown)")
        }
        let decoded = url.absoluteString.removingPercentEncoding ?? ""
        let hidden = decoded.unicodeScalars.first { [.control, .format].contains($0.properties.generalCategory) }
        try FuzzRun.check(hidden == nil, "U+\(String(hidden?.value ?? 0, radix: 16, uppercase: true)): \(shown)")
    }

    // MARK: - Link filter

    /// The filter's checks, run when the test says, in any order: a seeded interleaving.
    nonisolated final class ManualChecks: Sendable {
        private let jobs = Mutex<[@Sendable () -> Void]>([])
        private let changes = Mutex(0)
        /// Each check run: the check's generation, its text and folder, and its answer.
        private let log = Mutex<[(generation: Int, text: String, cwd: String?, isLink: Bool)]>([])

        func schedule(_ job: @escaping @Sendable () -> Void) { jobs.withLock { $0.append(job) } }
        var queued: Int { jobs.withLock { $0.count } }
        var changeCount: Int { changes.withLock { $0 } }
        func changed() { changes.withLock { $0 += 1 } }

        /// Runs job `index` and returns what its check answered.
        func run(_ index: Int) -> (generation: Int, text: String, cwd: String?, isLink: Bool)? {
            let job = jobs.withLock { $0.remove(at: index) }
            job()
            return log.withLock { $0.last }
        }

        /// The check of generation `generation`: a fixed answer per text and folder.
        func check(generation: Int) -> TerminalLinkCheck {
            { [self] text, cwd in
                let isLink = (text.utf8.count + (cwd?.utf8.count ?? 0) + generation) % 3 != 0
                log.withLock { $0.append((generation, text, cwd, isLink)) }
                return isLink
            }
        }
    }

    nonisolated private struct FilterKey: Hashable {
        var text: String
        var cwd: String?
    }

    /// Any sequence of hovers, check swaps, folder changes and finished checks against a model:
    /// no check is the answer "link"; otherwise a text is a link once the current check said so,
    /// a text asks one check at a time, a check started before a swap is dropped, and the view
    /// hears exactly once of each answer that changed and of each dropped check whose text the
    /// current check has not asked about (so Ghostty asks again).
    static func linkFilter(_ rng: inout FuzzRNG) throws {
        let checks = ManualChecks()
        let filter = TerminalLinkFilter(schedule: { checks.schedule($0) })
        filter.onChange { checks.changed() }
        let texts = ["a.txt", "/tmp/x", "src/main.swift:12", "", "🙂", "~/notes.md"]
        let folders: [String?] = [nil, "/", "/Users/fuzz", "/tmp"]
        var generation = 0, current: Int?, cwd: String?
        var answers: [FilterKey: Bool] = [:], pending: Set<FilterKey> = []
        for _ in 0..<rng.below(64) {
            switch rng.below(6) {
            case 0:
                generation += 1
                current = rng.oneIn(4) ? nil : generation
                filter.setCheck(current.map { checks.check(generation: $0) })
                answers.removeAll()
                pending.removeAll()
            case 1:
                cwd = rng.element(of: folders) ?? nil
                filter.setWorkingDirectory(cwd)
            case 2, 3:
                let text = rng.element(of: texts) ?? ""
                let key = FilterKey(text: text, cwd: cwd)
                let before = checks.queued
                let isLink = filter.isLink(text)
                let started = checks.queued - before
                guard current != nil else {
                    try FuzzRun.check(isLink && started == 0, "no check: \(text.debugDescription) is \(isLink), \(started) checks")
                    continue
                }
                try FuzzRun.check(isLink == (answers[key] ?? false), "\(key) is \(isLink), the model \(answers[key] as Any)")
                if pending.contains(key) {
                    try FuzzRun.check(started == 0, "\(key) asked a second check while one runs")
                } else if answers[key] == nil {
                    try FuzzRun.check(started == 1, "\(key) started \(started) checks")
                }
                if started == 1 { pending.insert(key) }
            default:
                guard checks.queued > 0 else { continue }
                let heard = checks.changeCount
                guard let ran = checks.run(rng.below(checks.queued)) else {
                    try FuzzRun.check(false, "a job ran no check")
                    continue
                }
                let key = FilterKey(text: ran.text, cwd: ran.cwd)
                var expected = 0
                if ran.generation == current {
                    if (answers[key] ?? false) != ran.isLink { expected = 1 }
                    answers[key] = ran.isLink
                    pending.remove(key)
                } else if answers[key] == nil, !pending.contains(key) {
                    // Dropped, and the current check has not asked: the view sends the pointer again.
                    expected = 1
                }
                try FuzzRun.check(checks.changeCount - heard == expected,
                                  "\(key) of generation \(ran.generation) (now \(String(describing: current))) told the view \(checks.changeCount - heard) times")
            }
        }
    }

    // MARK: - Runs

    @Test func wrappedLinksStayInsideTheirRows() throws {
        try FuzzRun("TerminalLink.wrapped", seed: 0x3A9_11E5, iterations: 6_000).forEach { rng in try Self.wrappedLink(&rng) }
    }

    @MainActor @Test func openedURLsAreWebOrLocalFiles() throws {
        try FuzzRun("TerminalLink.openURL", seed: 0x0FE_0081, iterations: 6_000).forEach { rng in try Self.openURL(&rng) }
    }

    @Test func linkFilterMatchesItsModel() throws {
        try FuzzRun("TerminalLink.filter", seed: 0xF117_E4, iterations: 3_000).forEach { rng in try Self.linkFilter(&rng) }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("TerminalLink.oneInput", seed: 0x11CC, iterations: 1_024)
        // Choice tapes: a first choice picks the property (even: wrapped link), then counts and piece indices.
        let tapes: [[UInt8]] = [[0, 1, 2, 0, 5, 1], [1, 8, 2, 3, 5, 5, 0, 1]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }

    /// A check started before the filter got a new one landed after the swap and answered for the
    /// new check, so a stale answer showed for up to 3 s.
    @Test func checkFromBeforeASwapIsDropped() {
        let checks = ManualChecks()
        let filter = TerminalLinkFilter(schedule: { checks.schedule($0) })
        filter.setCheck { _, _ in true }
        #expect(!filter.isLink("a.txt"))
        filter.setCheck { _, _ in false }
        #expect(!filter.isLink("a.txt"))
        #expect(checks.queued == 2)
        _ = checks.run(0)
        #expect(!filter.isLink("a.txt"))
        _ = checks.run(0)
        #expect(!filter.isLink("a.txt"))
    }

    /// The pointer rests on a path while the session swaps its check (TerminalSession.delegate
    /// changes): the old check's answer is dropped, so the view must send the pointer again for
    /// Ghostty to ask under the new check; without it the underline waits for the next move.
    @Test func droppedCheckAsksTheViewAgain() {
        let checks = ManualChecks()
        let filter = TerminalLinkFilter(schedule: { checks.schedule($0) })
        filter.onChange { checks.changed() }
        filter.setCheck { _, _ in true }
        #expect(!filter.isLink("a.txt"))
        filter.setCheck { _, _ in true }
        _ = checks.run(0)
        #expect(checks.changeCount == 1)
        #expect(!filter.isLink("a.txt"))
        #expect(checks.queued == 1)
        _ = checks.run(0)
        #expect(checks.changeCount == 2)
        #expect(filter.isLink("a.txt"))
    }
}
