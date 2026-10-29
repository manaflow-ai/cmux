/// The one-shot deadline of a page relay's idle close: a ``MainDeadline`` in the app, a fake in tests.
@MainActor
public protocol PageRelayIdleDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline (also one whose action is posted and still waiting).
    func cancel()
}

extension MainDeadline: PageRelayIdleDeadline {}

/// When a page relay closes its daemon connection: ``delay`` after its last use
/// ends. A call is a use while it runs, a listener while it is live (not paused by a frozen page).
/// 30 s is the idle timeout after which Chrome stops a service worker with no work
/// (content/browser/service_worker/service_worker_version.cc, `kIdleWorkerTimeout`): a tab switched
/// away and back keeps its connection, and pages nobody sees hold no daemon client. The app's page
/// relay channels (History and the other daemon pages) and the Chief editor's relay (Home and
/// Settings > Agents > Chiefs) both close this way.
@MainActor
public final class PageRelayIdleClose {
    /// How long the relay stays open after its last use ends.
    public static let delay: Duration = .seconds(30)

    /// Closes the connection; the owner sets it once.
    public var onIdle: (@MainActor () -> Void)?
    private let deadline: any PageRelayIdleDeadline
    private var uses = 0

    /// A closer whose idle deadline is `deadline`.
    public init(deadline: any PageRelayIdleDeadline) {
        self.deadline = deadline
    }

    /// A call starts or a listener goes live: the connection stays.
    public func begin() {
        uses += 1
        deadline.cancel()
    }

    /// A call ended or a listener stopped or paused; the last one arms the close.
    public func end() {
        uses = max(0, uses - 1)
        guard uses == 0 else { return }
        deadline.schedule(after: Self.delay) { [weak self] in
            guard let self, self.uses == 0 else { return }
            self.onIdle?()
        }
    }

    /// Whether a call or a live listener uses the connection now.
    public var inUse: Bool { uses > 0 }
}
