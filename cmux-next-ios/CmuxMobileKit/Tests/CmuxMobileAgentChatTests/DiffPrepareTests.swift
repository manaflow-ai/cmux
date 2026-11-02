import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileAgentChat
@testable import CmuxMobileArtifacts
@testable import CmuxMobileDiff

/// The diff and artifacts screens prepare their data once per content, not per body:
/// the line diff per edit list, the viewed fingerprint per file, the file screen's rows per
/// (file, options), the highlighter in one pass per line, thumbnails per artifact id.
@Suite(.serialized) struct DiffPrepareTests {
    static func code(_ lines: Int, edited: Bool) -> String {
        (0..<lines).map { line in
            edited && line % 7 == 0 ? "    let value\(line) = retried(\(line))" : "    let value\(line) = compute(\(line))"
        }.joined(separator: "\n")
    }

    /// 60 lines with edits at lines 10 and 40 only: two hunks with collapsed context around them.
    static let sparse = DiffFile(
        path: "x.swift",
        oldText: (0..<60).map { "line \($0)" }.joined(separator: "\n"),
        newText: (0..<60).map { $0 == 10 || $0 == 40 ? "line \($0) edited" : "line \($0)" }.joined(separator: "\n")
    )

    // MARK: Line diff memo

    @Test func editsDiffRunsOncePerEditList() {
        let path = "Sources/Memo-\(UUID().uuidString).swift"
        let edits: [(oldText: String?, newText: String)] = [(Self.code(400, edited: false), Self.code(400, edited: true))]
        func diffs() -> Int { DiffFile.editsDiffCounts.withLock { $0[path] ?? 0 } }
        let first = DiffFile(path: path, edits: edits)
        let again = (0..<20).map { _ in DiffFile(path: path, edits: edits) }
        #expect(diffs() == 1)
        #expect(again.allSatisfy { $0 == first })
        // A different edit list is its own diff.
        _ = DiffFile(path: path, edits: [(Self.code(40, edited: false), Self.code(40, edited: true))])
        #expect(diffs() == 2)
    }

    // MARK: Hunks

    @Test func hunkHeadersNameTheNearestDeclarationInLinearTime() {
        let old = "struct A {\n    func one() {\n        a\n    }\n    func two() {\n        b\n    }\n}\n"
        let new = "struct A {\n    func one() {\n        A\n    }\n    func two() {\n        B\n    }\n}\n"
        let file = DiffFile(path: "a.swift", oldText: old, newText: new)
        let headers = file.hunks(context: 0).map(\.header)
        #expect(headers == ["@@ -3,1 +3,1 @@ func one() {", "@@ -6,1 +6,1 @@ func two() {"])
        #expect(file.hunks().map(\.header) == ["@@ -1,8 +1,8 @@"])
        // The transcript's case: a 2400-line rewrite with a change every 7 lines and no declaration.
        let large = DiffFile(path: "large.swift", oldText: Self.code(2400, edited: false), newText: Self.code(2400, edited: true))
        let clock = ContinuousClock()
        var hunks: [DiffHunk] = []
        let elapsed = clock.measure { hunks = large.hunks(context: 1) }
        #expect(hunks.count > 300)
        #expect(elapsed < .milliseconds(500))
        let preview = large.unifiedPreview(maxLines: 12)
        #expect(preview.lines.count == 12)
        #expect(preview.remaining == hunks.reduce(0) { $0 + $1.range.count } - 12)
    }

    // MARK: Viewed fingerprint

    /// The fingerprint as it was computed per lookup before (FNV-1a over status, kind names and texts).
    static func legacyKey(_ file: DiffFile) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0x0A
            hash = hash &* 0x0000_0100_0000_01B3
        }
        mix(file.status.rawValue)
        for line in file.lines {
            mix("\(line.kind)")
            mix(line.text)
        }
        return file.path + "#" + String(hash, radix: 16)
    }

    @Test func viewedKeyIsUnchangedAndFollowsEdits() {
        var file = DiffFile(path: "a/b.swift", oldText: "a\n\tb\nc\n", newText: "a\n\tB\nc\nd\n")
        #expect(DiffViewedStore.key(for: file) == Self.legacyKey(file))
        #expect(file.additions == 2 && file.deletions == 1)
        file.lines.append(DiffLine(kind: .removed, oldNumber: 9, newNumber: nil, text: "gone"))
        #expect(DiffViewedStore.key(for: file) == Self.legacyKey(file))
        #expect(file.deletions == 2)
        file.status = .renamed
        #expect(DiffViewedStore.key(for: file) == Self.legacyKey(file))
    }

    // MARK: File screen rows

    @Test func rowsMatchHunksAndHeaders() {
        let file = Self.sparse
        let rows = DiffRows(file: file, options: .init())
        // Each visible range starts with a header that reads like the hunk's.
        let hunks = file.hunks()
        let headers = rows.rows.compactMap { row -> String? in if case .header(_, let text) = row { text } else { nil } }
        #expect(headers == hunks.map(\.header))
        let lines = rows.rows.compactMap { row -> Int? in if case .line(let index) = row { index } else { nil } }
        #expect(lines == hunks.flatMap { Array($0.range) })
        // Hidden context between and after the hunks collapses.
        #expect(rows.rows.contains { if case .collapsed = $0 { true } else { false } })
        #expect(hunks.count == 2)
        #expect(Set(rows.rows.map(\.id)).count == rows.rows.count)
        #expect(rows.longestColumns == file.lines.map { $0.text.count }.max())
    }

    @Test func expandingContextKeepsLineIDsAndAddsRows() throws {
        let file = Self.sparse
        let collapsed = DiffRows(file: file, options: .init())
        let range = try #require(collapsed.firstCollapsed)
        let expanded = DiffRows(file: file, options: .init(expanded: [range]))
        #expect(expanded.rows.count > collapsed.rows.count)
        let lineIDs = Set(collapsed.rows.filter { if case .line = $0 { true } else { false } }.map(\.id))
        #expect(lineIDs.isSubset(of: Set(expanded.rows.map(\.id))))
    }

    @Test func splitPairsRemovalsWithAdditions() {
        let file = DiffFile(path: "x.swift", oldText: "a\nb\nc\n", newText: "a\nB\nc\n")
        let rows = DiffRows(file: file, options: .init(split: true))
        let pairs = rows.rows.compactMap { row -> String? in
            if case .split(let left, let right) = row { "\(left.map { rows.lines[$0].text } ?? "-")|\(right.map { rows.lines[$0].text } ?? "-")" } else { nil }
        }
        #expect(pairs == ["a|a", "b|B", "c|c"])
    }

    @Test func hideWhitespaceDropsBlankChanges() {
        let file = DiffFile(path: "x.swift", oldText: "a\nb\n", newText: "a\n   \nb\n")
        #expect(DiffRows(file: file, options: .init()).lines.count == 3)
        #expect(DiffRows(file: file, options: .init(hideWhitespace: true)).lines.count == 2)
    }

    @Test func snippetEditsShowGaps() {
        let file = DiffFile(path: "s-\(UUID().uuidString).swift", edits: [("a", "b"), ("c", "d")])
        let rows = DiffRows(file: file, options: .init())
        #expect(rows.rows.contains { if case .gap = $0 { true } else { false } })
        #expect(!rows.rows.contains { if case .header = $0 { true } else { false } })
    }

    // MARK: Code preview highlighter

    @Test func highlighterMarksRolesInOnePass() {
        let roles = SyntaxHighlighter.roles(Array("let x = \"hi\" // done"), language: "swift")
        let expected: [SyntaxHighlighter.Role] = Array(repeating: .keyword, count: 3) + [.plain, .plain, .plain, .plain, .plain]
            + Array(repeating: .string, count: 4) + [.plain] + Array(repeating: .comment, count: 7)
        #expect(roles == expected)
        // Linear: a long line highlights in one pass (the old one copied the rest of the line per step).
        let long = String(repeating: "value + ", count: 20_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SyntaxHighlighter.highlight(long, language: "swift") }
        #expect(elapsed < .seconds(2))
        #expect(SyntaxHighlighter.highlightLines("a\nb\n", language: "swift").count == 3)
    }

    @Test func highlighterKeepsTheText() {
        let line = "<a href=\"x\">Ünïcode 🎉</a>"
        #expect(String(SyntaxHighlighter.highlight(line, language: "html").characters) == line)
        #expect(String(SyntaxHighlighter.highlight("let s = \"🎉\" // ü", language: "swift").characters) == "let s = \"🎉\" // ü")
    }

    // MARK: Artifacts

    @Test func filterCountsInOnePass() {
        let artifacts = [
            TerminalArtifact(reference: "a.png", kind: .image), TerminalArtifact(reference: "b.swift", kind: .code),
            TerminalArtifact(reference: "src/", kind: .directory), TerminalArtifact(reference: "https://x.dev", kind: .link),
            TerminalArtifact(reference: "c.md", kind: .markdown),
        ]
        let counts = ArtifactFilter.counts(artifacts)
        for filter in ArtifactFilter.allCases {
            #expect(counts[filter] == artifacts.count { filter.includes($0.kind) })
        }
    }

    @Test func memoSharesOneMakeAndStopsItWhenNoTileWaits() async {
        let memo = ArtifactMemo<String>(costLimit: 1 << 20)
        let artifact = TerminalArtifact(reference: "build/report.png", kind: .image, order: 1)
        let gate = AsyncStream<Void>.makeStream()
        let make: @Sendable (TerminalArtifact) async -> String? = { _ in
            for await _ in gate.stream { break }
            return Task.isCancelled ? nil : "thumb"
        }
        // Two tiles ask at once: one make. One scrolls away; the other still gets the thumbnail.
        func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
            for _ in 0..<10_000 where !condition() { await Task.yield() }
            // A wait that runs out fails here, not as a later expectation reading a half-done state.
            if !condition() { Issue.record("timed out waiting", sourceLocation: sourceLocation) }
        }
        let first = Task { await memo.value(for: artifact, scope: "diff-prepare-test", make: make) }
        await until { memo.waiting(for: artifact, scope: "diff-prepare-test") == 1 }
        let second = Task { await memo.value(for: artifact, scope: "diff-prepare-test") { _ in "other" } }
        await until { memo.waiting(for: artifact, scope: "diff-prepare-test") == 2 }
        first.cancel()
        gate.continuation.yield()
        #expect(await second.value == "thumb")
        _ = await first.value
        #expect(memo.cached(artifact, scope: "diff-prepare-test") == .some("thumb"))
        #expect(memo.makesStarted == 1)

        // The only tile scrolls away: the make stops and nothing is recorded, so it tries again later.
        let lone = TerminalArtifact(reference: "build/other.png", kind: .image, order: 2)
        let stopped = AsyncStream<Void>.makeStream()
        let alone = Task { await memo.value(for: lone, scope: "diff-prepare-test") { _ in
            for await _ in stopped.stream { break }
            return Task.isCancelled ? nil : "late"
        } }
        await until { memo.waiting(for: lone, scope: "diff-prepare-test") == 1 }
        alone.cancel()
        stopped.continuation.yield()
        _ = await alone.value
        #expect(memo.cached(lone, scope: "diff-prepare-test") == nil)
        #expect(await memo.value(for: lone, scope: "diff-prepare-test") { _ in "again" } == "again")

        // A new order or a non-edit detail is the same artifact; an edit makes a new thumbnail.
        let moved = TerminalArtifact(reference: "build/report.png", kind: .image, order: 9, detail: "Linked")
        #expect(await memo.value(for: moved, scope: "diff-prepare-test") { _ in "other" } == "thumb")
        let edited = TerminalArtifact(reference: "build/report.png", kind: .image, order: 9, detail: "Edited · +12 −4")
        #expect(await memo.value(for: edited, scope: "diff-prepare-test") { _ in "edited" } == "edited")
        // A real failure is remembered (no retry storm).
        let missing = TerminalArtifact(reference: "gone.png", kind: .image)
        _ = await memo.value(for: missing, scope: "diff-prepare-test") { _ in nil }
        #expect(memo.cached(missing, scope: "diff-prepare-test") == .some(nil))
    }

    /// A cancelled make that ends late never counts against the make that replaced it: two
    /// tiles wait on the new one, one scrolls away, and the other still gets its thumbnail.
    @Test func aLateCancelledMakeNeverStopsItsReplacement() async {
        let memo = ArtifactMemo<String>(costLimit: 1 << 20)
        let artifact = TerminalArtifact(reference: "build/late.png", kind: .image, order: 1)
        func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
            for _ in 0..<10_000 where !condition() { await Task.yield() }
            // A wait that runs out fails here, not as a later expectation reading a half-done state.
            if !condition() { Issue.record("timed out waiting", sourceLocation: sourceLocation) }
        }
        // The first make ignores its cancellation until its gate opens (a decode that never checks).
        let oldGate = AsyncStream<Void>.makeStream()
        let first = Task { await memo.value(for: artifact, scope: "diff-prepare-test") { _ in
            await Task.detached { for await _ in oldGate.stream { break } }.value
            return nil
        } }
        await until { memo.waiting(for: artifact, scope: "diff-prepare-test") == 1 }
        first.cancel()
        await until { memo.waiting(for: artifact, scope: "diff-prepare-test") == 0 }
        let newGate = AsyncStream<Void>.makeStream()
        let make: @Sendable (TerminalArtifact) async -> String? = { _ in
            for await _ in newGate.stream { break }
            return Task.isCancelled ? nil : "new"
        }
        let second = Task { await memo.value(for: artifact, scope: "diff-prepare-test", make: make) }
        await until { memo.waiting(for: artifact, scope: "diff-prepare-test") == 1 }
        let third = Task { await memo.value(for: artifact, scope: "diff-prepare-test", make: make) }
        await until { memo.waiting(for: artifact, scope: "diff-prepare-test") == 2 }
        // The old make ends now, and its tile leaves for the second time.
        oldGate.continuation.yield()
        _ = await first.value
        #expect(memo.waiting(for: artifact, scope: "diff-prepare-test") == 2)
        second.cancel()
        await until { memo.waiting(for: artifact, scope: "diff-prepare-test") == 1 }
        newGate.continuation.yield()
        #expect(await third.value == "new")
        #expect(memo.makesStarted == 2)
    }
}

/// An edited-files card's viewed marks follow the file's content: a new diff of the same
/// file with the same line and addition counts is not shown as already viewed.
#if os(iOS)
/// A diff file is prepared in place only when it is small in text, not only in lines: one
/// minified line of 200,000 characters is laid out off the main thread.
@Suite struct DiffInlineBuildTests {
    static func file(lines: Int, width: Int) -> DiffFile {
        let text = String(repeating: "x", count: width)
        return DiffFile(path: "a.js", status: .modified,
                        lines: (0..<lines).map { DiffLine(kind: .added, oldNumber: nil, newNumber: $0 + 1, text: text) },
                        hasFullContext: false)
    }

    @Test func aSmallFileIsPreparedInPlace() {
        #expect(DiffRenderer.preparesInPlace(Self.file(lines: 40, width: 80)))
    }

    @Test func aMinifiedLineIsPreparedOffMain() {
        #expect(!DiffRenderer.preparesInPlace(Self.file(lines: 1, width: 200_000)))
    }

    @Test func aLongFileIsPreparedOffMain() {
        #expect(!DiffRenderer.preparesInPlace(Self.file(lines: 400, width: 10)))
    }
}

@MainActor
@Suite struct CardViewedKeyTests {
    @Test func aChangedDiffWithTheSameCountsGetsItsOwnKey() {
        let first = DiffFile(path: "a/b.swift", oldText: "a\nb\n", newText: "a\nB\n")
        let second = DiffFile(path: "a/b.swift", oldText: "a\nc\n", newText: "a\nC\n")
        #expect(first.lines.count == second.lines.count && first.additions == second.additions)
        #expect(ChatNativeRowActions.viewedKey(first, in: "t-1") == DiffViewedStore.key(for: first))
        #expect(ChatNativeRowActions.viewedKey(second, in: "t-1") == DiffViewedStore.key(for: second))
        #expect(ChatNativeRowActions.viewedKey(first, in: "t-1") != ChatNativeRowActions.viewedKey(second, in: "t-1"))
    }
}

/// A code preview reused for another artifact never shows the previous file's lines while
/// the new file's highlight is still being prepared.
@Suite struct CodePreviewLinesTests {
    @Test func linesShowOnlyForTheSourceTheyWereMadeFrom() {
        let first = CodeView.Source(text: "let a = 1", language: "swift")
        let second = CodeView.Source(text: "print(2)", language: "python")
        let prepared = CodeView.PreparedLines(source: first, lines: [AttributedString("let a = 1")])
        #expect(prepared.lines(for: first).count == 1)
        #expect(prepared.lines(for: second).isEmpty)
        #expect(CodeView.PreparedLines().lines(for: first).isEmpty)
    }
}
#endif

#if os(iOS)
/// An HTML thumbnail scrolled away while the grid moves leaves the snapshot queue at once:
/// no queued task outlives its tile, and none resumes in a burst when the grid rests.
@MainActor
@Suite(.serialized) struct HTMLSnapshotQueueTests {
    @Test func aCancelledWaiterLeavesTheQueue() async throws {
        HTMLSnapshotter.setPaused(true)
        defer { HTMLSnapshotter.setPaused(false) }
        let before = HTMLSnapshotter.waitingCount
        let tile = Task { await HTMLSnapshotter.snapshot(html: "<p>x</p>", scale: 1) }
        for _ in 0..<200 where HTMLSnapshotter.waitingCount == before { await Task.yield() }
        #expect(HTMLSnapshotter.waitingCount == before + 1)
        tile.cancel()
        for _ in 0..<200 where HTMLSnapshotter.waitingCount != before { await Task.yield() }
        #expect(HTMLSnapshotter.waitingCount == before)
        HTMLSnapshotter.setPaused(false)
        #expect(await tile.value == nil)
    }
}
#endif
