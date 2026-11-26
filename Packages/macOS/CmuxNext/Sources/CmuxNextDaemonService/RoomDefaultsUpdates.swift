public import CmuxNextDaemon
import Foundation

/// Set and Clear Space Terminal Defaults… for one space, one at a time, each merging its named fields
/// into the defaults the daemon holds when it runs (`list-personal`), never into the app's mirror,
/// which lags a reply: two quick partial runs (`--cwd /a`, then `--env '{"X":"1"}'`) would both read
/// the old mirror, and the second's whole-object write would drop the first's field. One per app
/// (``AppServices/roomDefaults``).
@MainActor
public final class RoomDefaultsUpdates {
    public init() {}

    /// The newest run per space; the next run waits for it. Each entry ends with its run and is then
    /// removed, unless a newer run replaced it.
    private var tails: [ProfileID: (token: UUID, done: Task<Void, Never>)] = [:]

    /// Ends its stream when the command's body has run, or when the body is dropped unrun (no daemon
    /// connection): the body holds the only reference, so the next run never waits forever.
    private final class Finish: Sendable {
        let signal: AsyncStream<Void>.Continuation
        init(_ signal: AsyncStream<Void>.Continuation) { self.signal = signal }
        nonisolated deinit { signal.finish() }
    }

    /// Whether a run for `id` has not finished yet (its write may not have reached the mirror).
    public func inFlight(_ id: ProfileID) -> Bool { tails[id] != nil }

    /// Sends `id`'s defaults as `patch` makes them from the ones `daemon` holds when the run starts.
    public func apply(to id: ProfileID, on daemon: DaemonService,
                      _ patch: @escaping @Sendable (ProfileDefaults?) -> ProfileDefaults) {
        let previous = tails[id]?.done
        // Nothing is ever yielded; the stream only ends, so one slot is plenty.
        let (finished, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let finish = Finish(signal)
        let token = UUID()
        tails[id] = (token, Task { @MainActor [weak self] in
            for await _ in finished {}
            if self?.tails[id]?.token == token { self?.tails[id] = nil }
        })
        daemon.send("update-profile") { connection in
            defer { finish.signal.finish() }
            await previous?.value
            let current = try await connection.listPersonal().profiles.first(where: { $0.id == id })?.defaults
            let defaults = patch(current)
            try await connection.updateProfile(id, defaults: defaults.isEmpty ? .clear : .set(defaults))
        }
    }
}
