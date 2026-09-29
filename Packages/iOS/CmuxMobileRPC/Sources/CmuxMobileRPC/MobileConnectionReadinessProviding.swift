/// Lifecycle authority for starting foreground connections, supplied by the app.
@MainActor
public protocol MobileConnectionReadinessProviding: Sendable {
    /// Whether the app can currently access credentials and perform a dial.
    var permitsConnection: Bool { get }
    /// Replays current readiness, then emits lifecycle transitions without polling.
    func changes() -> AsyncStream<Bool>
}
