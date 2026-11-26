import Foundation

/// Serializes mouse input from the REPL sessions that drive one tab.
///
/// From a session's button down to its button up no other session's mouse
/// event reaches the page, so two sessions clicking one tab at once make two
/// clicks, not one. A session that never releases (its cell ended between
/// `mouse.down()` and `mouse.up()`) must not hang the others: a wait ends
/// after `timeout` with ``Held``.
@MainActor
public final class BrowserReplPointerOwner {
    /// Another session held the pointer for the whole wait.
    public struct Held: Error, Equatable, Sendable {
        /// The session that holds the pointer.
        public let owner: String
        public let timeout: Duration
    }

    /// The session whose press is in progress.
    public private(set) var owner: String?
    private let timeout: Duration
    private var releaseSignal = BrowserReplLatch()

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    /// Returns once no other session holds the pointer.
    /// - Throws: ``Held`` after `timeout` on `clock`, or `CancellationError`
    ///   when the waiting task is cancelled.
    public func waitForPointer<C: Clock>(
        sessionID: String,
        clock: C = ContinuousClock()
    ) async throws where C.Duration == Duration {
        let deadline = clock.now.advanced(by: timeout)
        while let current = owner, current != sessionID {
            let wasReleased = await releaseSignal.wait(until: deadline, clock: clock)
            try Task.checkCancellation()
            if !wasReleased, let holder = owner, holder != sessionID {
                throw Held(owner: holder, timeout: timeout)
            }
        }
    }

    /// Runs `gesture`, a press-to-release sequence in one call (a drag), as
    /// one press of `sessionID`: waits like ``waitForPointer(sessionID:clock:)``,
    /// holds the pointer while `gesture` runs, and releases it when
    /// `gesture` returns or throws. Another session's mouse input waits
    /// meanwhile, so its events never interleave with the gesture's.
    /// `ending` runs when `gesture` returns or throws, while the pointer is
    /// still held: it clears what the gesture armed (a drag capture, a held
    /// button), so no other session's input ever finds it.
    public func performGesture<T, C: Clock>(
        sessionID: String,
        clock: C = ContinuousClock(),
        ending: () -> Void = {},
        _ gesture: () async throws -> T
    ) async throws -> T where C.Duration == Duration {
        try await waitForPointer(sessionID: sessionID, clock: clock)
        pressed(sessionID: sessionID)
        defer {
            ending()
            released(sessionID: sessionID)
        }
        return try await gesture()
    }

    /// `sessionID` pressed a button; it owns the pointer until it releases.
    public func pressed(sessionID: String) {
        owner = sessionID
    }

    /// `sessionID` released its button, or ended; waiting sessions proceed.
    public func released(sessionID: String) {
        guard owner == sessionID else { return }
        owner = nil
        let latch = releaseSignal
        releaseSignal = BrowserReplLatch()
        latch.signal()
    }
}
