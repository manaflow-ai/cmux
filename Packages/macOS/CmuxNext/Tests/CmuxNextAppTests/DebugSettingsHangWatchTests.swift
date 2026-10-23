@testable import CmuxNextApp
@testable import CmuxNextControl
import CmuxNextPages
import CmuxNextSettingsWindow
import Foundation
import Testing

/// Debug Settings follows the recorder's hang files through ``HangEpisodeRecorder/changes()`` while
/// a page listens: a written hang file reaches the page as one `changed` event, and the last
/// listener leaving ends the recorder's stream.
@MainActor @Suite struct DebugSettingsHangWatchTests {
    @Test(.timeLimit(.minutes(1))) func aHangFileReachesThePageAndLeavingEndsTheWatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "debug-hangs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { $0.map { String($0) } })
        recorder.drain() // the (empty) folder of earlier launches is read: no change
        let provider = DebugSettingsPageProvider(model: DebugSettingsModel(store: TunableStore(), descriptors: []), hangs: recorder)
        let (events, received) = AsyncStream<JSONValue>.makeStream()
        let subscription = try await provider.subscribe("cmux.debug.tunables.changed", filter: [:],
                                                        context: PageCallContext(page: "cmux.debug-settings"),
                                                        onEvent: { received.yield($0) })
        #expect(recorder.subscriberCount == 1)

        recorder.begin(beat: 1, elapsed: .seconds(2), main: [1, 2], others: [])
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.objectValue?["state"]?.objectValue?["hangs"] != nil, "the hang file reached the page with no hangs state")

        // Both run on the main actor, so the watch is parked in its next() again here; cancelling it
        // ends the recorder's stream at once (AsyncStream's cancellation handler).
        subscription.cancel()
        #expect(recorder.subscriberCount == 0)
    }
}
