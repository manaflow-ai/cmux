import CmuxNextPalette
import Foundation
import Testing

/// A released ``TabSearchLiveUpdates`` stops following its source: its follow task is an
/// `OwnedTask`, so the release cancels it and the source's changes stream ends. Before it the task
/// was cancelled by a deinit that did nothing off the main thread.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TabSearchLiveUpdatesTests {
    /// A source whose changes stream reports when its follower went away.
    final class EndingSource: TabSearchSource {
        let ended: AsyncStream<Void>
        private let end: AsyncStream<Void>.Continuation
        private var continuations: [AsyncStream<Void>.Continuation] = []

        init() {
            let pair = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            ended = pair.stream
            end = pair.continuation
        }

        func changes() -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let end = end
            continuation.onTermination = { _ in end.yield() }
            continuations.append(continuation)
            return stream
        }

        func tabSearchEntries() -> [TabSearchEntry] { [] }
        func focusTab(id: String) {}
        func closeTab(id: String) {}
        func reopenClosedTab(id: String) {}
        func forgetClosedTab(id: String) {}
    }

    /// Updates that follow `source`, returned as their only reference.
    private static func following(_ source: EndingSource, in model: PaletteModel) -> TabSearchLiveUpdates {
        let updates = TabSearchLiveUpdates()
        updates.follow(source, in: model)
        return updates
    }

    @Test func releasingTheUpdatesEndsTheFollow() async {
        let source = EndingSource()
        let model = PaletteModel()
        var updates: TabSearchLiveUpdates? = TabSearchLiveUpdates()
        updates?.follow(source, in: model)
        updates = nil
        var ended = source.ended.makeAsyncIterator()
        #expect(await ended.next() != nil, "the follow ends once the updates are released")
        #expect(updates == nil)
        withExtendedLifetime(model) {}
    }

    /// The release off the main thread (the last reference dropped by a background task): the
    /// old deinit returned there without cancelling, and the follow ran on forever.
    @Test func releasingTheUpdatesOffTheMainThreadEndsTheFollow() async {
        let source = EndingSource()
        let model = PaletteModel()
        // The capture list holds the only reference, so the detached task drops the last one.
        await Task.detached { [updates = Self.following(source, in: model)] in _ = updates }.value
        var ended = source.ended.makeAsyncIterator()
        #expect(await ended.next() != nil, "the follow ends once the updates are released off the main thread")
        withExtendedLifetime(model) {}
    }

    @Test func stopEndsTheFollow() async {
        let source = EndingSource()
        let model = PaletteModel()
        let updates = TabSearchLiveUpdates()
        updates.follow(source, in: model)
        updates.stop()
        var ended = source.ended.makeAsyncIterator()
        #expect(await ended.next() != nil)
        withExtendedLifetime((model, updates)) {}
    }
}
