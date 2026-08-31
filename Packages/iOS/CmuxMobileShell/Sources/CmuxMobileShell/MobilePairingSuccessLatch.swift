/// Operation-scoped pairing completion marker.
///
/// A connection-state value can remain `.connected` while a second Mac is
/// paired, so observing that value cannot identify completion of this attempt.
/// The owning pairing operation marks this latch only after the target client
/// has authenticated and been published as the foreground connection.
@MainActor
final class MobilePairingSuccessLatch {
    private(set) var didSucceed = false

    /// Records semantic success for the operation that owns this latch.
    func markSucceeded() {
        didSucceed = true
    }
}
