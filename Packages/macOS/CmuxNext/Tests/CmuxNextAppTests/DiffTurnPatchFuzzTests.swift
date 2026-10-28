import CmuxFuzzSupport
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextDiff

/// The unified diff the diff page reads for a chat turn: ``DiffTurnPatch`` puts
/// git's headers back on the session host's `git.checkpoint.diff` reply and fixes the last hunk of a
/// patch the host cut short. Any reply (paths with quotes and control characters, CRLF and
/// combining-mark rows, cuts anywhere, hunk headers with huge or negative numbers, values of the
/// wrong JSON type) gives a patch whose hunks count their rows, or less, never a trap. Seeded
/// property tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS), built from the format's own
/// pieces as Chromium's structure-aware fuzzing guide does (testing/libfuzzer/structure_aware_fuzzing.md).
struct DiffTurnPatchFuzzTests {
    static let pathPieces = ["src", "/", "a.ts", "b c", "\"", "\\", "\n", "\t", "\u{1}", "\u{7F}", "é", "🙂", "-", "..", "a/", "b/", "dev/null"]
    static let statuses = ["modified", "added", "untracked", "deleted", "renamed", "copied", "", "Modified"]
    /// Row text after the mark: CRLF ends, a leading combining mark, and text that looks like diff syntax.
    static let rowTexts = ["", "a", "x y", "é", "\u{301}x", "🙂", "\t", "@@", "@@ -1 +1 @@", "diff --git a b", "--- a", "\\", "x\r", "+", "-"]
    static let oddHeaders = [
        "@@ -99999999999999999999,3 +1,3 @@", "@@ --5,3 +1 @@", "@@ -1,-2 +1,2 @@", "@@ -1", "@@", "@@ - + @@",
        "@@ -9223372036854775807,1 +1 @@", "@@ -1,2 +1,2 @", "@@@ -1,1 -1,1 +1,1 @@@",
    ]

    /// One file of the host's reply and the hunk rows its patch was made from.
    struct File {
        var json: [String: JSONValue]
        var path: String?
        var old: String
        var status: String
        var binary: Bool
        var truncated: Bool
        /// The whole patch's rows, before any cut.
        var rows: [String]
    }

    /// Well-formed hunks as git prints them: each header counts its rows (a count of 1 now and
    /// then left out, as git does), `\ No newline` rows count for neither side.
    static func hunkRows(_ rng: inout FuzzRNG) -> [String] {
        var out: [String] = []
        var start = 1
        for _ in 0..<rng.below(4) {
            var rows: [String] = []
            for _ in 0..<(1 + rng.below(6)) {
                rows.append((rng.element(of: [" ", "-", "+"]) ?? " ") + (rng.element(of: rowTexts) ?? ""))
            }
            if rng.oneIn(6) { rows.append("\\ No newline at end of file") }
            let (old, new) = counts(rows)
            // Git leaves out a count of 1; the host's reply may or may not.
            let short = rng.bool()
            let range = { (start: Int, count: Int) in count == 1 && short ? "\(start)" : "\(start),\(count)" }
            out.append("@@ -\(range(start, old)) +\(range(start, new)) @@" + (rng.oneIn(3) ? " func f() {" : ""))
            out += rows
            start += old + 10
        }
        return out
    }

    /// A hunk body's old and new row counts, read by the first byte (a combining mark after the
    /// mark is still a row of its side).
    static func counts(_ rows: some Collection<String>) -> (old: Int, new: Int) {
        let body = rows.filter { $0.utf8.first != UInt8(ascii: "\\") }
        return (body.filter { $0.utf8.first != UInt8(ascii: "+") }.count, body.filter { $0.utf8.first != UInt8(ascii: "-") }.count)
    }

    static func path(_ rng: inout FuzzRNG) -> String {
        var out = ""
        for _ in 0..<(1 + rng.below(5)) { out += rng.element(of: pathPieces) ?? "" }
        return out
    }

    /// `text` cut at any scalar, now and then at a row end.
    static func cut(_ text: String, _ rng: inout FuzzRNG) -> String {
        let scalars = Array(text.unicodeScalars)
        var at = rng.below(scalars.count + 1)
        if rng.oneIn(3), let end = scalars[..<at].lastIndex(of: "\n") { at = end + 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[..<at])
        return String(view)
    }

    static func makeFile(_ rng: inout FuzzRNG) -> File {
        let path = Self.path(&rng)
        let status = rng.element(of: statuses) ?? "modified"
        let previous: String? = status == "renamed" && !rng.oneIn(6) ? (rng.oneIn(6) ? path : Self.path(&rng)) : nil
        let binary = rng.oneIn(8)
        let rows = binary ? [] : hunkRows(&rng)
        let whole = rows.map { $0 + "\n" }.joined()
        let truncated = !rows.isEmpty && rng.oneIn(3)
        var patch = truncated ? cut(whole, &rng) : whole
        // The host's patch may lack its last line break.
        if !truncated, rng.oneIn(4), patch.utf8.last == UInt8(ascii: "\n") { patch = String(decoding: patch.utf8.dropLast(), as: UTF8.self) }
        var json: [String: JSONValue] = ["path": .string(path), "status": .string(status)]
        if let previous { json["previous_path"] = .string(previous) }
        if binary { json["binary"] = .bool(true) }
        if !patch.isEmpty { json["patch"] = .string(patch) }
        if truncated { json["patch_truncated"] = .bool(true) }
        if rng.oneIn(4) { json["additions"] = .number(Double(rng.below(4))) }
        let old = status == "renamed" ? previous ?? path : path
        return File(json: json, path: path, old: old, status: status, binary: binary, truncated: truncated, rows: rows)
    }

    /// One input of a property its first choice picks, replayed from bytes. Darwin only:
    /// CmuxNextDiff links CmuxNextAgentPane (AppKit), so the Linux libFuzzer targets
    /// skip it.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(3) {
        case 0: try wellFormed(&rng)
        case 1: try damaged(&rng)
        default: try quoting(&rng)
        }
    }

    // MARK: - Properties

    /// A reply of well-formed files, some cut short: one section per file with a path, in order,
    /// whose header rows hold no control character and name the file's paths (C-quoted when they
    /// must be), whose hunks are the file's rows (a prefix of them when cut) and count their rows.
    static func wellFormed(_ rng: inout FuzzRNG) throws {
        var files = (0..<rng.below(5)).map { _ in makeFile(&rng) }
        if rng.oneIn(8), !files.isEmpty { files[rng.below(files.count)].path = nil }
        let entries: [JSONValue] = files.map { file in
            var json = file.json
            if file.path == nil { json["path"] = rng.bool() ? JSONValue.number(7) : JSONValue.string("") }
            return .object(json)
        }
        let patch = DiffTurnPatch.make(.object(["files": .array(entries)]))
        let shown = "\(entries) gave \(patch.debugDescription)"
        try FuzzRun.check(patch.isEmpty || patch.utf8.last == UInt8(ascii: "\n"), "no last line break: \(shown)")
        var rows = Self.rows(patch)
        rows.removeLast()
        let starts = rows.indices.filter { rows[$0].hasPrefix("diff --git ") }
        let named = files.filter { $0.path != nil }
        try FuzzRun.check(starts.count == named.count && starts.first ?? 0 == 0, "\(starts.count) sections for \(named.count) files: \(shown)")
        for (index, file) in named.enumerated() {
            let section = rows[starts[index]..<(index + 1 < starts.count ? starts[index + 1] : rows.endIndex)]
            try checkSection(section, file, shown)
        }
    }

    static func checkSection(_ section: ArraySlice<String>, _ file: File, _ shown: String) throws {
        let path = file.path ?? ""
        let firstHunk = section.firstIndex { $0.hasPrefix("@@") } ?? section.endIndex
        let header = section[..<firstHunk]
        let control = header.first { row in row.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }
        try FuzzRun.check(control == nil, "a control character in header row \(control.debugDescription): \(shown)")
        let value = { (prefix: String) in header.first { $0.hasPrefix(prefix) }.map { unquote(String($0.dropFirst(prefix.count))) } }
        let added = file.status == "added" || file.status == "untracked", deleted = file.status == "deleted"
        try FuzzRun.check(header.contains("new file mode 100644") == added && header.contains("deleted file mode 100644") == deleted,
                          "file modes of \(file.status): \(shown)")
        try FuzzRun.check(value("rename from ") == (file.old != path ? file.old : nil) && value("rename to ") == (file.old != path ? path : nil),
                          "rename rows of \(file.old.debugDescription) to \(path.debugDescription): \(shown)")
        let hunks = Array(section[firstHunk...])
        try FuzzRun.check(file.binary == header.contains { $0.hasPrefix("Binary files ") } && (!file.binary || hunks.isEmpty),
                          "binary \(file.binary): \(shown)")
        if !file.truncated, !file.rows.isEmpty {
            try FuzzRun.check(hunks == file.rows, "rows of \(path.debugDescription) changed: \(shown)")
        }
        guard !hunks.isEmpty else {
            return try FuzzRun.check(value("--- ") == nil && value("+++ ") == nil, "file rows without hunks: \(shown)")
        }
        try FuzzRun.check(value("--- ") == (added ? "/dev/null" : "a/" + file.old) && value("+++ ") == (deleted ? "/dev/null" : "b/" + path),
                          "---/+++ rows of \(path.debugDescription): \(shown)")
        var at = hunks.startIndex
        while at < hunks.endIndex {
            let end = hunks[(at + 1)...].firstIndex { $0.hasPrefix("@@") } ?? hunks.endIndex
            guard let range = hunkRange(hunks[at]) else { return try FuzzRun.check(false, "header \(hunks[at].debugDescription): \(shown)") }
            let body = counts(hunks[(at + 1)..<end])
            try FuzzRun.check(range.old == body.old && range.new == body.new, "\(hunks[at]) counts \(body): \(shown)")
            at = end
        }
        let kept = hunks.filter { !$0.hasPrefix("@@") }.joined(separator: "\n")
        let all = file.rows.filter { !$0.hasPrefix("@@") }.joined(separator: "\n")
        try FuzzRun.check(all.unicodeScalars.starts(with: kept.unicodeScalars), "rows not from the file: \(shown)")
    }

    /// A damaged reply: byte edits of a patch, odd hunk headers, values of the wrong JSON type. Any
    /// of them gives text that ends with a line break, never a trap.
    static func damaged(_ rng: inout FuzzRNG) throws {
        let mutator = FuzzMutator(dictionary: ["\n", "\r\n", "@@ ", "@@ -", " +", ",", "\\", "+", "-", "\u{301}", "9999999999999999999"]
            .map { Data($0.utf8) })
        var entries: [JSONValue] = []
        for _ in 0..<rng.below(4) {
            var file = makeFile(&rng)
            var rows = file.rows
            if rng.oneIn(2), !rows.isEmpty {
                let headers = rows.indices.filter { rows[$0].hasPrefix("@@") }
                if let at = rng.element(of: headers) { rows[at] = rng.element(of: oddHeaders) ?? "@@" }
            }
            var patch = rows.map { $0 + "\n" }.joined()
            if rng.bool() { patch = String(decoding: mutator.mutate(Data(patch.utf8), using: &rng), as: UTF8.self) }
            if rng.bool() { patch = cut(patch, &rng) }
            file.json["patch"] = .string(patch)
            file.json["patch_truncated"] = rng.bool() ? JSONValue.bool(rng.bool()) : JSONValue.string("yes")
            if rng.oneIn(6) { file.json["patch"] = .number(3) }
            if rng.oneIn(6) { file.json["previous_path"] = .array([]) }
            entries.append(rng.oneIn(10) ? JSONValue.string("x") : JSONValue.object(file.json))
        }
        let reply: JSONValue = rng.oneIn(10) ? .object(["files": .string("x")]) : .object(["files": .array(entries)])
        let patch = DiffTurnPatch.make(reply)
        try FuzzRun.check(patch.isEmpty || patch.utf8.last == UInt8(ascii: "\n"), "no last line break: \(reply) gave \(patch.debugDescription)")
        for text in entries.compactMap({ $0["patch"]?.stringValue }) {
            let cut = DiffTurnPatch.cutHunks(text)
            try FuzzRun.check(cut.isEmpty || cut.utf8.last == UInt8(ascii: "\n"), "cut \(text.debugDescription) gave \(cut.debugDescription)")
        }
    }

    /// Git's C quoting: a quoted path reads back as the path, holds no control character, and is
    /// the path itself when nothing in it needs quoting.
    static func quoting(_ rng: inout FuzzRNG) throws {
        let path = Self.path(&rng)
        let quoted = DiffTurnPatch.quoted(path)
        try FuzzRun.check(unquote(quoted) == path, "\(path.debugDescription) quoted \(quoted.debugDescription)")
        try FuzzRun.check(!quoted.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, "control in \(quoted.debugDescription)")
        let plain = !path.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }
        try FuzzRun.check(plain == (quoted == path), "\(path.debugDescription) quoted \(quoted.debugDescription)")
    }

    // MARK: - Reading back

    /// `text`'s rows: split at each `\n` byte, as git writes them (a row may end in `\r`).
    static func rows(_ text: String) -> [String] {
        text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A hunk header's counts (`@@ -1,2 +3 @@`: a left-out count is 1); nil when it is not one.
    static func hunkRange(_ row: String) -> (old: Int, new: Int)? {
        let fields = row.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count >= 4, fields[0] == "@@", fields[3] == "@@", fields[1].hasPrefix("-"), fields[2].hasPrefix("+") else { return nil }
        let count = { (field: Substring) -> Int? in
            let parts = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
            return parts.count == 2 ? Int(parts[1]) : 1
        }
        guard let old = count(fields[1]), let new = count(fields[2]) else { return nil }
        return (old, new)
    }

    /// `text` with git's C quotes undone (`"a\"b\\c\n\001"`); `text` itself when it is not quoted.
    static func unquote(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else { return text }
        var bytes: [UInt8] = []
        var at = 1
        while at < scalars.count - 1 {
            let scalar = scalars[at]
            at += 1
            guard scalar == "\\", at < scalars.count - 1 else {
                bytes += Array(String(scalar).utf8)
                continue
            }
            let next = scalars[at]
            at += 1
            switch next {
            case "n": bytes.append(0x0A)
            case "t": bytes.append(0x09)
            case "\"", "\\": bytes.append(UInt8(next.value))
            case "0"..."7":
                var value = next.value - 0x30
                for _ in 0..<2 where at < scalars.count - 1 && ("0"..."7").contains(scalars[at]) {
                    value = value * 8 + scalars[at].value - 0x30
                    at += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes += Array("\\\(next)".utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Runs

    @Test func wellFormedRepliesGiveCountedHunks() throws {
        try FuzzRun("DiffTurnPatch.wellFormed", seed: 0x7A7C_4ED, iterations: 4_000).forEach { rng in try Self.wellFormed(&rng) }
    }

    @Test func damagedRepliesNeverTrap() throws {
        try FuzzRun("DiffTurnPatch.damaged", seed: 0xDA3A_6ED, iterations: 4_000).forEach { rng in try Self.damaged(&rng) }
    }

    @Test func quotedPathsReadBack() throws {
        try FuzzRun("DiffTurnPatch.quoting", seed: 0x0C_40E5, iterations: 3_000).forEach { rng in try Self.quoting(&rng) }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("DiffTurnPatch.oneInput", seed: 0x7A7C, iterations: 1_024)
        // Choice tapes: a first byte picks the property, then counts and piece indices.
        let tapes: [[UInt8]] = [[0, 2, 1, 3, 0, 2, 1], [1, 1, 2, 0, 4], [2, 3, 2, 6, 9]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }

    /// A CRLF file's rows end in `\r`, and `"\r\n"` is one Character: the cut patch was split into
    /// rows by Character, so its rows ran together and the last hunk got wrong counts; an untruncated
    /// patch ending in `\r\n` got an extra empty row.
    @Test func crlfRowsAreCountedAndKept() {
        #expect(DiffTurnPatch.cutHunks("@@ -1,3 +1,3 @@\n-a\r\n+b\r\n c\r") == "@@ -1,2 +1,2 @@\n-a\r\n+b\r\n c\r\n")
        let patch = DiffTurnPatch.make(.object(["files": .array([.object(["path": .string("a.txt"), "patch": .string("@@ -1 +1 @@\n-a\r\n+b\r\n")])])]))
        #expect(patch == "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\r\n+b\r\n")
    }

    /// A row that starts with a combining mark after its `+` or `-` is still that side's row.
    @Test func combiningMarkRowsCountForTheirSide() {
        #expect(DiffTurnPatch.cutHunks("@@ -1,2 +1,2 @@\n-\u{301}a\n+\u{301}b\n x") == "@@ -1,2 +1,2 @@\n-\u{301}a\n+\u{301}b\n x\n")
    }

    /// A cut inside a hunk header kept nothing: the hunks before it were lost with it.
    @Test func cutInsideAHeaderKeepsTheHunksBefore() {
        #expect(DiffTurnPatch.cutHunks("@@ -1 +1 @@\n-a\n+b\n@@ -9,") == "@@ -1,1 +1,1 @@\n-a\n+b\n")
    }
}
