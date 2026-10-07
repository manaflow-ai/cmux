/// One stream this client mirrors: the last applied seq and the subscriber's continuation.
struct StreamSubscription {
    var seq: UInt64?
    /// The owner's stream instance `seq` belongs to (B5 `epoch`); nil when the owner sends none.
    var epoch: String?
    /// A `snapshot.request` is out for a gap; later events wait for the snapshot.
    var repairing = false
    let continuation: AsyncStream<StreamUpdate>.Continuation
}
