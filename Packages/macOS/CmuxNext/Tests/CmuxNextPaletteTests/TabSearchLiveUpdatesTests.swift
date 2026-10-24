import CmuxNextPalette
import Foundation
import Testing

/// A released ``TabSearchLiveUpdates`` stops following its source: its follow task is an
/// `OwnedTask`, so the release cancels it and the source's changes stream ends. Before it the task
/// was cancelled by a deinit that did nothing off the main thread. Its `nonisolated deinit {}`
/// keeps the release on the releasing thread: an implicit deinit is isolated in this target and
/// hops to the main actor (the cx-t7hu trap inside an action's task-local scope).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TabSearchLiveUpdatesTests {
    /// A source whose changes stream reports when its follower first waits in it, and when (and
    /// on which thread) that follower went away.
    final class EndingSource: TabSearchSource {
        /// One element once the follow task asked the changes stream for its first element.
        let started: AsyncStream<Void>
        /// Whether the follow ended on the main thread (one element per end).
        let ended: AsyncStream<Bool>
        private let start: AsyncStream<Void>.Continuation
        private let end: AsyncStream<Bool>.Continuation

        init() {
            let starts = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            started = starts.stream
            start = starts.continuation
            let ends = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
            ended = ends.stream
            end = ends.continuation
        }

        /// A stream that yields nothing. Its first `next()` reports `started`, then waits until
        /// the follow task is cancelled; the cancel ends the wait on the cancelling thread, which
        /// `ended` reports. A follow cancelled before it asked (`onCancel`) reports the thread
        /// that asks.
        func changes() -> AsyncStream<Void> {
            let start = start
            let end = end
            return AsyncStream(unfolding: {
                start.yield()
                let (wait, waiting) = AsyncStream.makeStream(of: Void.self)
                waiting.onTermination = { _ in end.yield(Thread.isMainThread) }
                for await _ in wait {}
                waiting.finish()
                return nil
            }, onCancel: { end.yield(Thread.isMainThread) })
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

    /// Moves the reference out of `value`: the caller's capture then holds the only one.
    private static func handOff<Value>(_ value: inout Value?) -> Value? {
        defer { value = nil }
        return value
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
    /// old deinit returned there without cancelling, and the follow ran on forever. The follow
    /// ends on the releasing thread: with an isolated (implicit) deinit the release hopped to the
    /// main actor, and the stream ended there.
    @Test func releasingTheUpdatesOffTheMainThreadEndsTheFollowThere() async {
        let source = EndingSource()
        let model = PaletteModel()
        var updates: TabSearchLiveUpdates? = Self.following(source, in: model)
        // The follow task reports when it asks the changes stream for its first element (no
        // reliance on the order of main-actor jobs). From then on a cancel ends its wait on the
        // thread that cancels. A gap between the report and the wait exists only when the stream
        // runs off the main actor; a cancel in that gap ends the wait on that thread, also not main.
        var started = source.started.makeAsyncIterator()
        #expect(await started.next() != nil, "the follow task waits in the changes stream")
        // The capture holds the only reference, and the detached task never runs on the main
        // actor: it completes on a cooperative-pool thread, and its completion drops the last
        // reference there. (A main-actor turn inside it let a Release build complete it on the
        // main thread, so that release did not test the off-main path.)
        await Task.detached { [updates = Self.handOff(&updates)] in
            _ = updates
        }.value
        #expect(updates == nil)
        // The source reports the thread its stream ended on: false proves the cancel, so the
        // release, ran off the main thread.
        var ended = source.ended.makeAsyncIterator()
        #expect(await ended.next() == false, "the follow ends on the releasing thread, not after a hop to the main actor")
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
