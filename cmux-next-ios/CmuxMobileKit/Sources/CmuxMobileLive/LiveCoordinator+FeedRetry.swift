#if os(iOS)
import CmuxMobileTransport

extension LiveCoordinator {
    /// Recover the Feed's application channel without redialing a healthy Mac link.
    /// The Retry control owns this task; the existing readiness waiter stops on
    /// readiness, cancellation or its bounded timeout and removes its waiter/timer.
    public func reconnectFeed(macID: String) async {
        guard canLink(macID: macID), !Task.isCancelled else { return }
        if let session = sessions[macID], session.link.phase.isConnected,
           session.servedLink != nil {
            // A channel can close while the underlying Mac link remains healthy.
            // Probe it before deciding that `isReady` means it can still be read.
            if session.acpmux.isReady {
                do {
                    try await session.feed.refresh()
                    return
                } catch is CancellationError {
                    return
                } catch {}
            } else if session.chatsError == nil {
                // Initial serving already owns the bind. Do not race it with a second one.
                _ = await session.acpmux.waitUntilReady(timeout: .seconds(20), clock: clock)
                return
            }
            do {
                try Task.checkCancellation()
                let link = try await pairedLink(session)
                let channel = try await link.openChannel(service: "acpmux", args: [:])
                guard !Task.isCancelled, session.currentLink === link,
                      sessions[macID] === session else {
                    await channel.close(code: "eof", reason: "recovery cancelled or link replaced")
                    return
                }
                await session.acpmux.bind(channel)
                guard session.currentLink === link, !Task.isCancelled else { return }
                session.chatsError = session.acpmux.isReady ? nil : session.acpmux.lastError
                if session.acpmux.isReady { feedStore.syncState = .live }
                phaseChanged(session)
            } catch is CancellationError {
            } catch {
                session.chatsError = LinkController.reason(error)
            }
        } else {
            retry(macID: macID)
            guard let session = sessions[macID] else { return }
            _ = await session.acpmux.waitUntilReady(timeout: .seconds(20), clock: clock)
        }
    }
}
#endif
