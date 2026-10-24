@testable import CmuxNextApp
@testable import CmuxNextControl
import CmuxNextDesignTokens
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow
import Dispatch
import Foundation
import Testing

/// Debug Settings follows the recorder's hang files through ``HangEpisodeRecorder/changes()``
/// while a page listens: each hang file written reaches every listening page with the files on
/// disk in its state, the recorder keeps one stream however many pages listen, and the stream
/// goes when the last page leaves or the provider goes away. A page opened again follows the
/// files again.
///
/// The symbolicator waits until the test ends, so the only changes are the writes the test makes.
@MainActor @Suite struct DebugSettingsHangWatchTests {
    @Test(.timeLimit(.minutes(1))) func aPageThatLeavesAndComesBackFollowsTheHangFilesAgain() async throws {
        let (directory, symbolsMayRun, recorder) = Self.recorder()
        defer { Self.finish(directory, symbolsMayRun, recorder) }
        let provider = Self.provider(recorder)

        let (first, firstEvents) = try await Self.listen(provider)
        #expect(recorder.subscriberCount == 1)
        recorder.begin(beat: 1, elapsed: .seconds(30), main: [1, 2], others: [])
        var firstIterator = firstEvents.makeAsyncIterator()
        let written = Self.paths(await firstIterator.next())
        #expect(written.count == 1, "the page's state lists \(written.count) hang files after one write")
        #expect(written == Self.hangFiles(in: directory), "the page's state does not list the written file")

        first.cancel()
        #expect(recorder.subscriberCount == 0, "the last page left and the recorder still holds its stream")

        // The page opens again: it follows the hang files with a new stream.
        let (second, secondEvents) = try await Self.listen(provider)
        defer { second.cancel() }
        try #require(recorder.subscriberCount == 1, "a page opened again does not follow the hang files")
        recorder.begin(beat: 2, elapsed: .seconds(2), main: [3], others: [])
        var secondIterator = secondEvents.makeAsyncIterator()
        let rewritten = Self.paths(await secondIterator.next())
        #expect(rewritten.count == 2)
        #expect(rewritten == Self.hangFiles(in: directory), "the reopened page's state does not list the new file first")
    }

    @Test(.timeLimit(.minutes(1))) func onePageLeavingKeepsTheOtherFollowingOnOneStream() async throws {
        let (directory, symbolsMayRun, recorder) = Self.recorder()
        defer { Self.finish(directory, symbolsMayRun, recorder) }
        let provider = Self.provider(recorder)

        let (leaving, leavingEvents) = try await Self.listen(provider)
        let (staying, stayingEvents) = try await Self.listen(provider)
        defer { staying.cancel() }
        #expect(recorder.subscriberCount == 1, "two pages hold \(recorder.subscriberCount) streams")

        recorder.begin(beat: 1, elapsed: .seconds(30), main: [1], others: [])
        var leavingIterator = leavingEvents.makeAsyncIterator()
        var stayingIterator = stayingEvents.makeAsyncIterator()
        let leavingSaw = Self.paths(await leavingIterator.next())
        let stayingSaw = Self.paths(await stayingIterator.next())
        #expect(leavingSaw.count == 1)
        #expect(leavingSaw == Self.hangFiles(in: directory))
        #expect(stayingSaw == leavingSaw)

        leaving.cancel()
        #expect(recorder.subscriberCount == 1, "one page left and the other's stream went with it")
        recorder.begin(beat: 2, elapsed: .seconds(2), main: [2], others: [])
        let after = Self.paths(await stayingIterator.next())
        #expect(after.count == 2)
        #expect(after == Self.hangFiles(in: directory), "the staying page missed the second file")
    }

    /// A provider released while a page still listens (no unsubscribe) ends its watch at once:
    /// the recorder holds no stream for it.
    @Test(.timeLimit(.minutes(1))) func aReleasedProviderEndsItsHangWatch() async throws {
        let (directory, symbolsMayRun, recorder) = Self.recorder()
        defer { Self.finish(directory, symbolsMayRun, recorder) }
        let subscription: PageSubscription
        weak var released: DebugSettingsPageProvider?
        do {
            let provider = Self.provider(recorder)
            let (listening, events) = try await Self.listen(provider)
            subscription = listening
            // One event: the watch task has run and waits in the stream for the next change.
            recorder.begin(beat: 1, elapsed: .seconds(2), main: [1], others: [])
            var iterator = events.makeAsyncIterator()
            let written = Self.paths(await iterator.next())
            #expect(written == Self.hangFiles(in: directory))
            released = provider
        }
        #expect(released == nil, "the provider outlived its last reference")
        #expect(recorder.subscriberCount == 0, "a released provider's hang watch still holds the recorder's stream")
        subscription.cancel()
    }

    // MARK: Helpers

    /// A recorder in a fresh folder whose symbolicator waits for the semaphore (a latch: once
    /// signalled, every later symbolication runs too).
    private static func recorder() -> (URL, DispatchSemaphore, HangEpisodeRecorder) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "debug-hangs-\(UUID().uuidString)")
        let symbolsMayRun = DispatchSemaphore(value: 0)
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { addresses in
            symbolsMayRun.wait()
            symbolsMayRun.signal()
            return addresses.map { String($0) }
        })
        recorder.drain(symbols: false) // the (empty) folder of earlier launches is read: no change
        return (directory, symbolsMayRun, recorder)
    }

    /// Lets the waiting symbolications run, waits for them, and removes the folder. Runs on every
    /// exit (a failed expectation, a thrown error or the time limit too), so no symbol queue
    /// worker stays blocked after the test.
    private static func finish(_ directory: URL, _ symbolsMayRun: DispatchSemaphore, _ recorder: HangEpisodeRecorder) {
        symbolsMayRun.signal()
        recorder.drain()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func provider(_ recorder: HangEpisodeRecorder) -> DebugSettingsPageProvider {
        DebugSettingsPageProvider(model: DebugSettingsModel(store: TunableStore(), descriptors: []), hangs: recorder)
    }

    /// One page listening to `changed`: its subscription and the events it receives.
    private static func listen(_ provider: DebugSettingsPageProvider) async throws -> (PageSubscription, AsyncStream<JSONValue>) {
        let (events, received) = AsyncStream<JSONValue>.makeStream()
        let subscription = try await provider.subscribe("cmux.debug.tunables.changed", filter: [:],
                                                        context: PageCallContext(page: "cmux.debug-settings"),
                                                        onEvent: { received.yield($0) })
        return (subscription, events)
    }

    /// The `path` of each hang the event's state lists, in its order (newest first).
    private static func paths(_ event: JSONValue?) -> [String] {
        let items = event?.objectValue?["state"]?.objectValue?["hangs"]?.objectValue?["items"]?.arrayValue ?? []
        return items.compactMap { $0.objectValue?["path"]?.stringValue }
    }

    /// The hang files on disk, newest first (their names sort by start time).
    private static func hangFiles(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(HangEpisodeRecorder.filePrefix) && $0.hasSuffix(".txt") }.sorted(by: >)
            .map { directory.appending(path: $0).path }
    }
}
