@testable import CmuxNextApp
@testable import CmuxNextControl
import CmuxNextDesignTokens
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow
import Dispatch
import Foundation
import Testing

/// Debug Settings follows the recorder's hang files through ``HangEpisodeRecorder/changes()`` while
/// a page listens: writing a hang file reaches the page as exactly one `changed` event, and after
/// the last listener leaves, a later change of the same file (its symbols) reaches no page and the
/// recorder holds no stream.
@MainActor @Suite struct DebugSettingsHangWatchTests {
    @Test(.timeLimit(.minutes(1))) func aHangFileIsOneEventAndNothingArrivesAfterTheLastListenerLeaves() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "debug-hangs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // The symbolicator waits for the test, so the file's second change (its symbols) comes only
        // after the page left.
        let symbolsMayRun = DispatchSemaphore(value: 0)
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { addresses in
            symbolsMayRun.wait()
            return addresses.map { String($0) }
        })
        recorder.drain(symbols: false) // the (empty) folder of earlier launches is read: no change
        let provider = DebugSettingsPageProvider(model: DebugSettingsModel(store: TunableStore(), descriptors: []), hangs: recorder)
        let (events, received) = AsyncStream<JSONValue>.makeStream()
        let subscription = try await provider.subscribe("cmux.debug.tunables.changed", filter: [:],
                                                        context: PageCallContext(page: "cmux.debug-settings"),
                                                        onEvent: { received.yield($0) })
        #expect(recorder.subscriberCount == 1)

        recorder.begin(beat: 1, elapsed: .seconds(2), main: [1, 2], others: [])
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.objectValue?["state"]?.objectValue?["hangs"] != nil, "the hang file reached the page with no hangs state")

        // The last listener leaves; then the symbols are written into the same file.
        subscription.cancel()
        #expect(recorder.subscriberCount == 0)
        symbolsMayRun.signal()
        recorder.drain()
        #expect(recorder.entries.first?.topFrames == ["1", "2"], "the symbols were not written")

        received.finish()
        var later = 0
        while await iterator.next() != nil { later += 1 }
        #expect(later == 0, "\(later) events reached the page after the write's one event or after it left")
    }
}
