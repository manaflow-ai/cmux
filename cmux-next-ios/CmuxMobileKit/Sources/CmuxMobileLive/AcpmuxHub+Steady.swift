import CmuxConnectivityTelemetry
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "acpmux")

/// Requests that ride out a blip instead of showing it (Leo 2026-11-21: "i keep seeing "the mac
/// didnt answer in time" i dont want to see that").
///
/// Before this, every request went to the channel as it was at that moment:
/// - during a reconnect (every foreground after the app was in the background redials) there was
///   no channel, and the request failed at once with "Not connected";
/// - when the `acpmux` channel went quiet while the Mac's link stayed healthy (its heartbeat
///   probes the link, not the channel), each read waited its whole 20 to 30 s deadline and then
///   said the Mac didn't answer. Only the Feed's Retry button opened a fresh channel.
///
/// Now a request waits, bounded, for a channel that is coming back, and an idempotent read that
/// goes unanswered for ``stallAfter`` (or loses its channel) has the hub recover the channel once
/// (``onStall``, one recovery shared by every read that stalled) and is asked again on the new one.
/// Mutations and prompts are never sent twice.
extension AcpmuxHub {
    /// A channel coming back (a redial after the app was in the background, a rebind) is ready
    /// within a few seconds; past this the request says offline.
    nonisolated static let defaultReadyGrace: Duration = .seconds(10)
    /// A read the Mac has not answered in this long counts as stalled. A page is at most a few
    /// hundred rows, answered in well under a second on a healthy channel, even over a relay.
    nonisolated static let defaultStallAfter: Duration = .seconds(6)

    /// Reads that change nothing on the Mac: safe to ask again on a fresh channel.
    nonisolated static let steadyMethods: Set<String> = [
        "_acpmux/sessions", "_acpmux/watch", "_acpmux/harnesses", "_acpmux/info",
        "_acpmux/events", "_acpmux/models", "_acpmux/attachment",
    ]

    /// Failures of the channel or link itself (not the Mac's answer): worth a fresh channel.
    nonisolated static func isChannelFailure(_ error: any Error) -> Bool {
        guard let error = error as? LinkError else { return false }
        return ["timeout", "closed", "offline", "reply_timeout", "write_timeout", "eof"].contains(error.code)
    }

    /// The current channel, or the next one if it is coming back (bounded by ``readyGrace``).
    func liveConnection() async throws -> AcpmuxConnection {
        if let connection { return connection }
        return try await readyConnection()
    }

    /// The current channel once it is ready, waiting for it at most ``readyGrace``.
    func readyConnection() async throws -> AcpmuxConnection {
        if isReady, let connection { return connection }
        if steadyReads {
            let ready = await waitUntilReady(timeout: readyGrace, clock: steadyClock)
            try Task.checkCancellation()
            if ready, let connection { return connection }
        }
        throw LinkError(code: "offline", message: "Not connected to the Mac")
    }

    /// `body` on the current channel; for a read in ``steadyMethods``, recovered and retried once.
    /// `stallWatch`: a read unanswered past ``stallAfter`` recovers the channel (its own reply then
    /// fails as closed, and it is asked again on the new channel).
    func steady<T: Sendable>(_ method: String, stallWatch: Bool,
                             _ body: @MainActor (AcpmuxConnection) async throws -> T) async throws -> T {
        guard steadyReads else {
            guard let connection else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
            return try await body(connection)
        }
        let first = try await liveConnection()
        guard Self.steadyMethods.contains(method) else { return try await body(first) }
        let watch: Task<Void, Never>? = stallWatch && onStall != nil ? Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.steadyClock.sleep(for: self.stallAfter)
            guard !Task.isCancelled else { return }
            await self.recover(from: first, why: "stalled", method: method)
        } : nil
        defer { watch?.cancel() }
        do {
            return try await body(first)
        } catch where Self.isChannelFailure(error) && !Task.isCancelled {
            await recover(from: first, why: (error as? LinkError)?.code ?? "other", method: method)
            // Not replaced (its link is down and comes back on its own, or nothing recovers this
            // hub): asking the same channel again would only wait again.
            if connection === first { throw error }
            let next = try await liveConnection()
            let answer = try await body(next)
            ConnectivityTelemetry.shared.record(.hub, "read_recovered", outcome: .success,
                                                fields: ["method": .text(method)])
            return answer
        }
    }

    /// Recovers the channel `stale` once: every read that stalled on it waits on the same
    /// recovery. A channel already replaced needs none.
    func recover(from stale: AcpmuxConnection, why: String, method: String) async {
        if let recovering {
            await recovering.value
            return
        }
        // The stalled channel is still bound, or it closed under a link that may still be up
        // (nothing else rebinds then; a link that is down makes `onStall` a no-op and its own
        // reconnect binds the next channel).
        guard connection === stale || connection == nil, let onStall else { return }
        // A read that is only slow behind a prompt or mutation on a healthy channel is left to its
        // own deadline: replacing the channel would cut that work off. The channel is asked a
        // cheap read first: answered, it is alive (busy, not stalled); unanswered, it is dead and
        // its write is lost with it, so it is recovered. A closed channel has nothing left to lose.
        // "stalled" and "timeout" are both a channel that is still open and has not answered.
        if why == "stalled" || why == "timeout", await stale.hasWritesInFlight, await Self.answers(stale, within: stallAfter) {
            log.info("acpmux read \(method, privacy: .public) slow behind a write on a live channel: not recovering")
            return
        }
        // Asked again: another read may have started a recovery while this one waited above.
        if let recovering {
            await recovering.value
            return
        }
        // A recovery that started and finished during the probe already replaced `stale`: a second
        // one would rebind a channel that is healthy.
        guard connection === stale || connection == nil else { return }
        log.info("acpmux channel \(why, privacy: .public) on \(method, privacy: .public): recovering")
        ConnectivityTelemetry.shared.record(.hub, "channel_recover", outcome: .failure,
                                            fields: ["why": .text(why), "method": .text(method)])
        let task = Task { @MainActor in await onStall() }
        recovering = task
        await task.value
        if recovering == task { recovering = nil }
    }

    /// Whether `channel` still answers: a cheap idempotent read (the harness list), bounded.
    static func answers(_ channel: AcpmuxConnection, within bound: Duration) async -> Bool {
        (try? await channel.request("_acpmux/harnesses", .object([:]), timeout: bound)) != nil
    }
}
