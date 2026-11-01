import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
import class CmuxNextDaemon.DaemonStore // only the store: the whole module makes JSONValue ambiguous (CmuxNextSettings has one too)
import CmuxNextDesignTokens
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow
import Dispatch
import Foundation
import Testing

/// Debug Settings follows the recorder's hang files through ``HangEpisodeRecorder/changes()``
/// while a page listens: each hang file written reaches every listening page with the files on
/// disk in its state, one change is one event, the recorder keeps one stream however many pages
/// listen, and the stream goes when the last page leaves, which closing the tab does. A page
/// opened again follows the files again.
///
/// The symbolicator waits until the test ends, so the only changes are the writes the test makes.
@MainActor @Suite struct DebugSettingsHangWatchTests {
    /// AppServices reads `NSApp` (an implicitly unwrapped Optional) from its observers and services;
    /// a suite run in its own process has no shared application until something makes it.
    init() { _ = NSApplication.shared }

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

    /// One hang file change is one page event: a write, then a known other change (a search),
    /// then a second write reach the page as exactly those three events, in that order. A second
    /// event for one change (the Observation watch and the hang watch both answering it, or the
    /// recorder telling it twice) would be a second full state build and bridge send on the main
    /// thread, and shows here as an event out of place.
    @Test(.timeLimit(.minutes(1))) func oneHangFileChangeIsOnePageEvent() async throws {
        let (directory, symbolsMayRun, recorder) = Self.recorder()
        defer { Self.finish(directory, symbolsMayRun, recorder) }
        let provider = Self.provider(recorder)
        let (listening, events) = try await Self.listen(provider)
        defer { listening.cancel() }
        var iterator = events.makeAsyncIterator()

        recorder.begin(beat: 1, elapsed: .seconds(30), main: [1], others: [])
        let first = await iterator.next()
        #expect(Self.paths(first).count == 1, "the first event is not the first hang file")

        _ = try await provider.call("cmux.debug.tunables.view.set", params: ["query": "marker"],
                                    context: PageCallContext(page: "cmux.debug-settings"))
        let marker = await iterator.next()
        #expect(marker?.objectValue?["state"]?.objectValue?["query"]?.stringValue == "marker",
                "a second event for the first hang file came before the search's event")
        #expect(Self.paths(marker).count == 1)

        recorder.begin(beat: 2, elapsed: .seconds(2), main: [2], others: [])
        let second = await iterator.next()
        #expect(Self.paths(second).count == 2, "a second event for one change came before the second hang file's event")
        #expect(Self.paths(second) == Self.hangFiles(in: directory))
    }

    /// Closing a Debug Settings tab through the tab store (the path of Cmd-W, the close button and
    /// a closed pane) ends its page's subscriptions: the recorder forgets the page's stream. The
    /// router's event handler holds the provider, so before the service closed the page each tab
    /// opened and closed left a provider that followed the hang files and rebuilt its state on
    /// every change for the rest of the session.
    @Test(.timeLimit(.minutes(1))) func closingTheTabEndsItsPageHangWatch() async throws {
        let (directory, symbolsMayRun, recorder) = Self.recorder()
        defer { Self.finish(directory, symbolsMayRun, recorder) }
        let root = try #require(Self.pageRoot, "no scratch page root")
        PageID.registerBundledRoot(root, for: PageDescriptor.debugSettings.id) // the built page wins when bundled
        let services = AppServices(environment: AppEnvironment.current([:]))
        let watchdog = MainThreadWatchdog() // never started: it only hands the recorder to the page
        watchdog.episodes = recorder
        services.quit.watchdog = watchdog
        services.pages.register(services.debugSettings)

        let key = services.pages.open(.debugSettings, in: "pane-debug-settings-hangs", of: DaemonStore())
        let view = try #require(services.pages.view(for: key))
        let page = try #require(view.content as? PageWebView, "Debug Settings did not open as its React page")
        await page.waitUntilLoaded() // a document committing later would reset the router itself
        let (delivered, deliver) = AsyncStream<JSONValue>.makeStream()
        let send = page.router.sendWithDrop
        page.router.sendWithDrop = { envelope, dropped in
            send?(envelope, dropped)
            deliver.yield(envelope)
        }
        let reply = await page.router.handle(["t": "sub", "id": .number(1), "stream": "cmux.debug.tunables.changed",
                                              "filter": .object([:])])
        let sub = try #require(reply["value"]?.objectValue?["sub"]?.doubleValue, "the page could not subscribe: \(reply)")
        #expect(recorder.subscriberCount == 1)

        // A hang file reaches the page: the hang watch runs and waits in the stream again.
        recorder.begin(beat: 1, elapsed: .seconds(2), main: [1], others: [])
        var envelopes = delivered.makeAsyncIterator()
        var event: JSONValue?
        while let envelope = await envelopes.next() {
            guard envelope["t"]?.stringValue == "ev", envelope["sub"]?.doubleValue == sub else { continue }
            event = envelope["data"]
            break
        }
        #expect(Self.paths(event) == Self.hangFiles(in: directory), "the page did not get the hang file")

        services.pages.close(key)
        #expect(recorder.subscriberCount == 0, "the closed tab's page still follows the hang files")
        #expect(page.router.subscriptionCount == 0, "the closed tab's page still has subscriptions")
        withExtendedLifetime(watchdog) {}
    }

        // MARK: Helpers

    /// A scratch Debug Settings page (an empty document), for a test build without the built
    /// page. Registered once per process; never deleted, as the registration outlives the test.
    private static let pageRoot: URL? = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "debug-settings-page-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body></body></html>".utf8).write(to: directory.appending(path: "index.html"))) != nil
        else { return nil }
        return directory
    }()

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
