public import CmuxNextBrowserCore
public import Foundation

/// A profile's omnibox history persistence: the daemon's visit store (`history-v1`). Every write goes
/// through one FIFO, so a title never overtakes the visit it names. While the local daemon
/// (re)connects, the FIFO holds the writes (at most `capacity`, the oldest dropped past it) and
/// sends them once it serves history again; a visit keeps the time it was made (`at_ms`).
public final class DaemonVisitSink: BrowserHistoryPersistence {
    public static let capacity = 4_096
    /// A page removed from the history (Remove from History, Shift-Delete in the omnibar): the
    /// import store drops its imported copy too, so it does not come back at the next launch.
    public var onRemove: ((URL) -> Void)?
    private let profile: String
    private let continuation: AsyncStream<@Sendable (DaemonHistoryClient) async -> Void>.Continuation
    private let drain: Task<Void, Never>

    public init(profile: String, daemon: @escaping @MainActor () async -> DaemonHistoryClient?) {
        self.profile = profile
        let (stream, continuation) = AsyncStream<@Sendable (DaemonHistoryClient) async -> Void>
            .makeStream(bufferingPolicy: .bufferingNewest(Self.capacity))
        self.continuation = continuation
        // task-owner: the sink's lifetime; ends when the stream finishes or the task is cancelled in deinit
        drain = Task {
            for await write in stream {
                guard let client = await daemon() else { return }
                await write(client)
            }
        }
    }

    // A deleted profile's queued writes go with it.
    nonisolated deinit {
        continuation.finish()
        drain.cancel()
    }

    public func didRecordVisit(url: URL, title: String?, at date: Date) {
        let profile = profile, text = url.absoluteString
        continuation.yield { try? await $0.recordVisit(profile: profile, url: text, title: title, tab: nil, at: date) }
    }

    public func didUpdateTitle(_ title: String, for url: URL) {
        let profile = profile, text = url.absoluteString
        continuation.yield { try? await $0.updateTitle(profile: profile, url: text, title: title) }
    }

    public func didRemoveEntry(for url: URL) {
        onRemove?(url)
        let profile = profile, text = url.absoluteString
        continuation.yield { try? await $0.removeVisits(profile: profile, url: text) }
    }
}
