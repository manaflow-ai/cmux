import Foundation
import Testing

@testable import CmuxFoundation

/// Classifying a sidebar file must not read the filesystem on the main thread, and must not read it
/// at all until it has to.
///
/// A custom sidebar re-renders about once a second, and both hosting surfaces used to classify their
/// file from a SwiftUI view builder. For a `.url` sidebar that is a whole-file read plus a line scan
/// on the main thread on every pass — a stall the user feels as sidebar-wide jank, and one no amount
/// of caching downstream can undo, because the read sits in the render path itself.
@Suite("Custom sidebar classification off the main thread")
struct CustomSidebarSourceOffMainThreadTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-offmain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a `.url` file whose parse is slow enough to be unmistakable if it happens inline.
    ///
    /// The URL is on the last line behind a few hundred thousand comment lines, so the parser has to
    /// walk the whole file — the same code path a one-line file takes, just long enough to measure.
    private func writeSlowURLFile(in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent("board.url", isDirectory: false)
        var contents = String(repeating: "# padding line that is not a url\n", count: 400_000)
        contents += "http://127.0.0.1:8787/\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// The blocking classifier, timed on the main actor, establishes that the fixture is genuinely
    /// slow. Without this the off-main test below could pass on a file that parses instantly.
    @MainActor
    @Test("the fixture is slow enough that a main-thread parse would be visible")
    func blockingClassificationIsMeasurablySlow() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try writeSlowURLFile(in: directory)

        let start = DispatchTime.now()
        let source = CustomSidebarSource.classify(fileURL: fileURL)
        let elapsed = Self.milliseconds(since: start)

        #expect(source == .web(.remote(URL(string: "http://127.0.0.1:8787/")!)))
        #expect(elapsed > 50, "fixture parsed in \(elapsed)ms; too fast to detect a main-thread stall")
    }

    /// The behaviour that matters: while the same file is being classified, the main actor keeps
    /// servicing work.
    ///
    /// A main-thread read shows up as one long gap between heartbeats, roughly the parse time from
    /// the test above. Off the main thread the heartbeats stay tight regardless of how slow the parse
    /// is.
    ///
    /// Best of several runs: ambient work on a loaded machine can only ever add to a measurement, so
    /// the minimum is the closest thing to this code's own cost — and an inline read would land in
    /// every run, floor included.
    @MainActor
    @Test("classifying a .url sidebar leaves the main actor responsive")
    func urlFileIsReadOffTheMainThread() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try writeSlowURLFile(in: directory)

        var bestGapMilliseconds = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            // A main-actor heartbeat that runs for as long as the classification does. Each
            // iteration records how long the main actor went without servicing it.
            let heartbeat = Task { @MainActor () -> Double in
                var longest: Double = 0
                var last = DispatchTime.now()
                while !Task.isCancelled {
                    await Task.yield()
                    let now = DispatchTime.now()
                    longest = max(longest, Self.milliseconds(between: last, and: now))
                    last = now
                }
                return longest
            }

            let source = await CustomSidebarSource.classifying(fileURL: fileURL)
            heartbeat.cancel()
            #expect(source == .web(.remote(URL(string: "http://127.0.0.1:8787/")!)))
            bestGapMilliseconds = min(bestGapMilliseconds, await heartbeat.value)
        }

        // Generous: the parse measured above is hundreds of milliseconds, so an inline read cannot
        // hide under this, while ordinary scheduling noise stays well below it.
        #expect(
            bestGapMilliseconds < 50,
            "main actor stalled \(bestGapMilliseconds)ms during classification"
        )
    }

    /// The non-blocking half: for every extension whose kind follows from its name, the answer must
    /// be available with no filesystem access. A file that does not exist at all still classifies,
    /// which is what proves nothing was read.
    @Test(
        "an extension that decides the kind classifies with no filesystem access",
        arguments: ["board.swift", "board.json", "board.html", "board.txt"]
    )
    func nonURLExtensionsNeedNoRead(name: String) {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/\(name)")
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        switch CustomSidebarSource.classifyWithoutReading(fileURL: missing) {
        case let .decided(source):
            // The decided answer agrees with the blocking classifier.
            #expect(source == CustomSidebarSource.classify(fileURL: missing))
        case .needsURLFileRead:
            Issue.record("\(name) should not require reading the file")
        }
    }

    @Test("a .url file is the only kind that needs its bytes read")
    func urlExtensionNeedsARead() {
        let url = URL(fileURLWithPath: "/sidebars/board.url")
        #expect(CustomSidebarSource.classifyWithoutReading(fileURL: url) == .needsURLFileRead(url))
    }

    /// The async and blocking classifiers must never disagree, or the sidebar renders one thing and
    /// `cmux sidebar validate` reports another.
    @Test(
        "the non-blocking classifier agrees with the blocking one on every source shape",
        arguments: [
            ("board.swift", "Text(\"hi\")"),
            ("board.json", "{\"version\":1}"),
            ("board.html", "<!doctype html>"),
            ("board.url", "http://127.0.0.1:8787/"),
            ("board.url", "[InternetShortcut]\nURL=https://example.com/x\n"),
            ("board.url", "file:///etc/passwd"),
            ("board.url", ""),
            ("board.txt", "whatever"),
            ("board.HTML", "<!doctype html>"),
        ]
    )
    func asyncAgreesWithBlocking(name: String, contents: String) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(await CustomSidebarSource.classifying(fileURL: fileURL)
            == CustomSidebarSource.classify(fileURL: fileURL))
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        milliseconds(between: start, and: DispatchTime.now())
    }

    private static func milliseconds(between start: DispatchTime, and end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}
