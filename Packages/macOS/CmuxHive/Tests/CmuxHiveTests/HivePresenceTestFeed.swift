import CmuxMobileShell

/// Supplies buffered presence events without a socket or scheduling sleeps.
struct HivePresenceTestFeed: PresenceSubscribing {
    let events = AsyncThrowingStream<PresenceUpdate, any Error>.makeStream()

    func subscribe() async throws -> AsyncThrowingStream<PresenceUpdate, any Error> {
        events.stream
    }
}
