import CmuxNextPalette
import Foundation
import Testing

/// Scratch diagnostic (never lands): where does a detached task's capture get released, and does
/// the follow task start before the off-main release cancels it?
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DiagTabSearchReleaseTests {
    final class Probe: Sendable {
        let report: AsyncStream<Bool>.Continuation
        init(_ report: AsyncStream<Bool>.Continuation) { self.report = report }
        deinit { report.yield(Thread.isMainThread) }
    }

    final class Source: TabSearchSource {
        let ended: AsyncStream<Bool>
        let end: AsyncStream<Bool>.Continuation
        init() {
            let pair = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
            ended = pair.stream
            end = pair.continuation
        }
        func changes() -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let end = end
            continuation.onTermination = { _ in end.yield(Thread.isMainThread) }
            return stream
        }
        func tabSearchEntries() -> [TabSearchEntry] { [] }
        func focusTab(id: String) {}
        func closeTab(id: String) {}
        func reopenClosedTab(id: String) {}
        func forgetClosedTab(id: String) {}
    }

    @Test func whereIsTheCaptureReleased() async {
        let (released, report) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        await Task.detached { [probe = Probe(report)] in
            await MainActor.run {}
            _ = probe
        }.value
        var it = released.makeAsyncIterator()
        let onMain = await it.next()
        print("DIAG-CAPTURE released_on_main=\(String(describing: onMain))")
    }

    private static func following(_ source: Source, in model: PaletteModel) -> TabSearchLiveUpdates {
        let updates = TabSearchLiveUpdates()
        updates.follow(source, in: model)
        return updates
    }

    @Test func whereDoesTheUpdatesDeinitAndTheStreamEnd() async {
        let source = Source()
        let model = PaletteModel()
        let (released, report) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        await Task.detached { [updates = Self.following(source, in: model), probe = Probe(report)] in
            await MainActor.run {}
            _ = updates
            _ = probe
        }.value
        var r = released.makeAsyncIterator()
        var e = source.ended.makeAsyncIterator()
        let probeOnMain = await r.next()
        let endOnMain = await e.next()
        print("DIAG-FOLLOW capture_released_on_main=\(String(describing: probeOnMain)) stream_ended_on_main=\(String(describing: endOnMain))")
        withExtendedLifetime(model) {}
    }
}
