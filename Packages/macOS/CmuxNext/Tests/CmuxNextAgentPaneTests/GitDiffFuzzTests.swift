import CmuxFuzzSupport
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The unified diff the App reads back to stage one hunk: git's output of a
/// file the user's programs wrote, and the hunk and paths the Changes page names. A well-formed
/// diff gives exactly the named hunk's patch; any damaged diff or request gives the file's header
/// and the one hunk with the named lines, or nothing, never a trap. The turn patch the diff page
/// reads (CmuxNextDiff's DiffTurnPatch) has its own suite, DiffTurnPatchFuzzTests in
/// CmuxNextAppTests. Seeded property tests on CmuxFuzzSupport (long mode:
/// CMUX_FUZZ_SECONDS), built from the format's own pieces as Chromium's structure-aware fuzzing
/// guide does (testing/libfuzzer/structure_aware_fuzzing.md).
struct GitDiffFuzzTests {
    static let lineTexts = ["", "a", "line 2", "é", "🙂", "\t", "x y", "@@", "diff --git", "--- a", "+++ b", "\\", "\u{0}"]
    static let modeLines = ["old mode 100644", "new mode 100755"]
    /// The rows git's diff prints before a file's first hunk, less the mode change a hunk patch drops
    /// (git's Documentation/diff-generate-patch.txt).
    static let headerRows = [
        "diff --git ", "index ", "--- ", "+++ ", "similarity index ", "dissimilarity index ", "rename from ",
        "rename to ", "copy from ", "copy to ", "new file mode ", "deleted file mode ",
    ]

    struct Diff {
        var header: [String]
        var hunks: [[String]]

        var text: String {
            (header + hunks.flatMap { $0 }).joined(separator: "\n") + "\n"
        }

        /// A hunk's lines as the page names them: no `\ No newline` markers.
        static func content(_ hunk: [String]) -> [String] {
            hunk.dropFirst().filter { !$0.hasPrefix("\\") }
        }
    }

    static func makeDiff(_ rng: inout FuzzRNG) -> Diff {
        var header = ["diff --git a/f.txt b/f.txt"]
        if rng.oneIn(4) { header += modeLines }
        header += ["index 1111111..2222222 100644", "--- a/f.txt", "+++ b/f.txt"]
        var hunks: [[String]] = []
        for index in 0..<(1 + rng.below(4)) {
            var hunk = ["@@ -\(index * 10 + 1),3 +\(index * 10 + 1),3 @@"]
            for _ in 0..<(1 + rng.below(5)) {
                let mark = rng.element(of: [" ", "-", "+"]) ?? " "
                hunk.append(mark + (rng.element(of: lineTexts) ?? ""))
            }
            if rng.oneIn(6) { hunk.append("\\ No newline at end of file") }
            // A hunk with a change, as git prints.
            if !hunk.dropFirst().contains(where: { $0.hasPrefix("-") || $0.hasPrefix("+") }) { hunk.append("+x") }
            hunks.append(hunk)
        }
        return Diff(header: header, hunks: hunks)
    }

    /// One input of a property its first choice picks, replayed from bytes. Darwin only:
    /// CmuxNextAgentPane imports AppKit, so the Linux libFuzzer targets skip it.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(3) {
        case 0: try wellFormed(&rng)
        case 1: try damaged(&rng)
        default: try stageRequest(&rng)
        }
    }

    /// A well-formed diff: a hunk whose lines no other hunk has gives the header without mode
    /// lines and that hunk; a hunk whose lines another hunk shares gives nothing.
    static func wellFormed(_ rng: inout FuzzRNG) throws {
        let diff = makeDiff(&rng)
        let pick = rng.below(diff.hunks.count)
        let lines = Diff.content(diff.hunks[pick])
        let patch = AgentPaneGitHunk.patch(of: lines, in: diff.text)
        let same = diff.hunks.filter { Diff.content($0) == lines }.count
        guard same == 1 else {
            return try FuzzRun.check(patch == nil, "\(same) hunks have \(lines), patch \(patch.debugDescription)")
        }
        let header = diff.header.filter { !modeLines.contains($0) }
        let expected = (header + diff.hunks[pick]).joined(separator: "\n") + "\n"
        try FuzzRun.check(patch == expected, "hunk \(pick) of \(diff.text.debugDescription) gave \(patch.debugDescription)")
    }

    /// A damaged diff (byte edits of a well-formed one) with any hunk lines: nothing, or a patch of
    /// one file's header rows (no mode change) and the one hunk whose rows are those lines. The
    /// hunk is git's own text: its counts are checked by `git apply`, whose refusal Stage hunk shows.
    static func damaged(_ rng: inout FuzzRNG) throws {
        let source = makeDiff(&rng)
        let mutator = FuzzMutator(dictionary: ["\n", "@@", "diff --git ", "\\", "+", "-", " ", "rename from x", "\u{FFFD}"]
            .map { Data($0.utf8) })
        let text = String(decoding: mutator.mutate(Data(source.text.utf8), using: &rng), as: UTF8.self)
        let lines: [String] = if rng.bool() {
            Diff.content(source.hunks[rng.below(source.hunks.count)])
        } else {
            (0..<rng.below(4)).map { _ in (rng.element(of: [" ", "-", "+", ""]) ?? "") + (rng.element(of: lineTexts) ?? "") }
        }
        guard let patch = AgentPaneGitHunk.patch(of: lines, in: text) else { return }
        let shown = "\(lines) in \(text.debugDescription) gave \(patch.debugDescription)"
        try FuzzRun.check(patch.hasPrefix("diff --git ") && patch.utf8.last == UInt8(ascii: "\n") && !patch.contains("\u{FFFD}"),
                          "not one file's patch: \(shown)")
        let rows = patch.dropLast().components(separatedBy: "\n")
        let hunkAt = rows.firstIndex { $0.hasPrefix("@@") } ?? rows.endIndex
        try FuzzRun.check(rows[..<hunkAt].allSatisfy { row in headerRows.contains { row.hasPrefix($0) } }
                          && rows.filter { $0.hasPrefix("diff --git ") }.count == 1,
                          "header rows: \(shown)")
        try FuzzRun.check(hunkAt < rows.endIndex && rows[(hunkAt + 1)...].allSatisfy { !$0.hasPrefix("@@") }, "not one hunk: \(shown)")
        let body = rows[min(hunkAt + 1, rows.endIndex)...].filter { !$0.hasPrefix("\\") }
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        try FuzzRun.check(body == lines, "not the named hunk: \(shown)")
    }

    /// Stage and Unstage requests from the page: any params build a request that keeps the rules
    /// (absolute folder, 1 to maximumPaths paths inside the repository, a hunk for one file or a
    /// rename) or none.
    static func stageRequest(_ rng: inout FuzzRNG) throws {
        let methods = ["git.stage", "git.unstage", "git.stageHunk", "git.unstageHunk", "git.diff", ""]
        let pathPieces = ["a", "b/c", ".", "..", "", "/", "/abs", "a//b", "x\u{0}", "é", "-n", ":(glob)*"]
        var params: [String: Any] = [:]
        if !rng.oneIn(8) {
            params["cwd"] = rng.element(of: ["/repo", "repo", "", "/r\u{0}", "/", 7] as [Any]) ?? ""
        }
        if !rng.oneIn(8) {
            let paths: [String] = if rng.oneIn(16) {
                Array(repeating: "a", count: AgentPaneGitStage.maximumPaths + rng.below(2))
            } else {
                (0..<rng.below(4)).map { _ in rng.element(of: pathPieces) ?? "" }
            }
            params["paths"] = paths
        }
        if rng.bool() {
            let hunk: [String] = (0..<rng.below(5)).map { _ in
                (rng.element(of: [" ", "-", "+", "", "x"]) ?? "") + (rng.element(of: lineTexts + ["\n", "\r"]) ?? "")
            }
            params["hunk"] = hunk
        }
        let method = rng.element(of: methods) ?? ""
        guard let request = AgentPaneGitStage(method: method, params: rng.oneIn(16) ? nil : params) else { return }
        let shown = "\(method) \(params) gave \(request)"
        try FuzzRun.check(request.cwd.hasPrefix("/") && !request.cwd.contains("\u{0}"), "folder: \(shown)")
        try FuzzRun.check((1...AgentPaneGitStage.maximumPaths).contains(request.paths.count), "path count: \(shown)")
        try FuzzRun.check(request.paths.allSatisfy { AgentPaneGitStage.isInside($0) }, "a path outside: \(shown)")
        if let hunk = request.hunk {
            try FuzzRun.check(method.hasSuffix("Hunk") && AgentPaneGitStage.isHunk(hunk) && request.paths.count <= 2, "hunk: \(shown)")
        } else {
            try FuzzRun.check(!method.hasSuffix("Hunk"), "a hunk request without a hunk: \(shown)")
        }
        let arguments = request.arguments(in: "/repo")
        try FuzzRun.check(arguments.firstIndex(of: "--").map { arguments[($0 + 1)...].allSatisfy { $0.hasPrefix(":(top,literal)") } } ?? false,
                          "pathspecs not literal: \(arguments)")
    }

    // MARK: - Runs

    @Test func wellFormedDiffGivesTheNamedHunk() throws {
        try FuzzRun("GitDiff.wellFormed", seed: 0xD1FF, iterations: 4_000).forEach { rng in try Self.wellFormed(&rng) }
    }

    @Test func damagedDiffGivesAPatchOrNothing() throws {
        try FuzzRun("GitDiff.damaged", seed: 0xDA3A_6E, iterations: 6_000).forEach { rng in try Self.damaged(&rng) }
    }

    @Test func stageRequestsKeepTheirRules() throws {
        try FuzzRun("GitDiff.stageRequest", seed: 0x57A6E, iterations: 4_000).forEach { rng in try Self.stageRequest(&rng) }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("GitDiff.oneInput", seed: 0x0D1F, iterations: 1_024)
        // Choice tapes: a first byte picks the property, then counts and piece indices.
        let tapes: [[UInt8]] = [[0, 0, 1, 2, 1], [1, 1, 0, 3, 0], [2, 1, 0, 1, 2, 0, 0]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }
}
