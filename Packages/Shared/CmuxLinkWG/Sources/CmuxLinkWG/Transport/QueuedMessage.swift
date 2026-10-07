/// One fragment of an unordered or partial lane message, waiting to send.
struct QueuedMessage {
    let frame: [UInt8]
    let enqueuedAt: Duration
    /// Partial lanes: dropped at dequeue once older than this.
    let lifetime: Duration?
}
