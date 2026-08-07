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

    /// Creates a `.url` sidebar whose read parks until the test decides to complete it.
    ///
    /// A FIFO is a file whose `open` for reading blocks until a writer arrives, so it puts the read
    /// under the test's control exactly: the read is *in progress*, and stays that way, until the
    /// test says otherwise. That is what makes the claim below an ordering fact rather than a
    /// measurement — no fixture has to be large enough to be slow, and nothing depends on how loaded
    /// the machine is.
    private func makeParkedURLFile(in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent("board.url", isDirectory: false)
        let created = mkfifo(fileURL.path, 0o600)
        try #require(created == 0, "mkfifo failed with errno \(errno)")
        return fileURL
    }

    /// The behaviour that matters: while a `.url` file is being read, the main actor keeps servicing
    /// work.
    ///
    /// Asserted as causality. The read parks in the FIFO; the main actor then completes a round trip
    /// and only afterwards releases the writer that lets the read finish. An inline read would hold
    /// the main thread inside `open`, so the round trip could not complete, and the writer's release
    /// would never be signalled — which is exactly the expectation that fails. The writer proceeds
    /// on its own after a bounded wait regardless, so the failing case reports rather than hangs.
    @MainActor
    @Test("classifying a .url sidebar leaves the main actor free while the read is in flight")
    func urlFileIsReadOffTheMainThread() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try makeParkedURLFile(in: directory)

        let mainActorRanFirst = Signal()
        let writerFinished = Signal()
        let observed = Observation()
        Thread.detachNewThread {
            // Recorded, not asserted here: what the test claims is that the main actor ran *before*
            // the read was allowed to finish.
            observed.mainActorRanBeforeWrite = mainActorRanFirst.waitBounded()
            if let handle = FileHandle(forWritingAtPath: fileURL.path) {
                try? handle.write(contentsOf: Data("http://127.0.0.1:8787/\n".utf8))
                try? handle.close()
            }
            writerFinished.signal()
        }

        // Inherits the main actor, so an inline read would block the main thread here.
        let classification = Task { @MainActor in
            await CustomSidebarSource.classifying(fileURL: fileURL)
        }

        // A main-actor round trip. It can only complete if the main thread is not sitting inside the
        // parked read.
        await MainActor.run {}
        await Task.yield()
        mainActorRanFirst.signal()

        let source = await classification.value
        _ = writerFinished.waitBounded()

        #expect(observed.mainActorRanBeforeWrite, "the main actor was blocked by the .url read")
        #expect(source == .web(.remote(URL(string: "http://127.0.0.1:8787/")!)))
    }

    /// A one-shot cross-thread signal.
    ///
    /// The bounded wait is a safety valve so a blocked main actor reports as a failed expectation
    /// instead of hanging the suite; nothing is asserted about how long it took.
    private final class Signal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func signal() { semaphore.signal() }

        /// Waits for the signal, giving up after long enough that only a real block reaches it.
        /// Returns whether the signal arrived.
        func waitBounded() -> Bool {
            semaphore.wait(timeout: .now() + 30) == .success
        }
    }

    /// What the writer thread saw, read back on the main actor once it has finished.
    private final class Observation: @unchecked Sendable {
        var mainActorRanBeforeWrite = false
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
}
