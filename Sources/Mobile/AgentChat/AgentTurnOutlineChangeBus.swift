import CmuxMobileHost
import Foundation

/// Fan-out of "this surface's turn outline may have changed" wakeups.
///
/// Each observer gets a stream that buffers at most one pending wakeup, so a
/// burst of transcript batches coalesces into one refresh.
@MainActor
final class AgentTurnOutlineChangeBus {
    private struct Observer {
        let surfaceID: String
        let continuation: AsyncStream<Void>.Continuation
    }

    private var observers: [UUID: Observer] = [:]

    /// Number of live observers, for tests and diagnostics.
    var observerCount: Int { observers.count }

    /// A wakeup stream for one terminal surface. The stream ends when the
    /// consuming task is cancelled.
    func stream(surfaceID: String) -> AsyncStream<Void> {
        let observerID = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[observerID] = Observer(surfaceID: surfaceID, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.observers.removeValue(forKey: observerID)
            }
        }
        return stream
    }

    /// Wakes observers of any of the given surfaces.
    func yield(surfaceIDs: [String?]) {
        let targets = Set(surfaceIDs.compactMap { $0 }.filter { !$0.isEmpty })
        guard !targets.isEmpty else { return }
        for observer in observers.values where targets.contains(observer.surfaceID) {
            observer.continuation.yield()
        }
    }

    /// Whether a registry record change can change which session (or
    /// transcript) a surface's outline reads. Pure activity bumps cannot.
    nonisolated static func affectsOutline(
        _ record: AgentChatSessionRecord,
        previous: AgentChatSessionRecord?
    ) -> Bool {
        guard let previous else { return true }
        return previous.state != record.state
            || previous.surfaceID != record.surfaceID
            || previous.transcriptPath != record.transcriptPath
    }
}
