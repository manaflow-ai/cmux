/// Why auto-archive did not act, with the message the person reads (the sweep's "nothing idle", no
/// sidebar document yet, the daemon's refusal).
public nonisolated struct AutoArchiveRefusal: Error, Equatable, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
}
