import CmuxNextWakeups
import Foundation

/// The start of one terminal that a daemon with `terminal-async-start-v1` admitted before its host
/// was up (F10, p05-ipc-130): the command asked for it (`async_start`), its reply says
/// `starting: true`, and the daemon reports the host's launch on the control sequence as
/// `terminal-started`, or as `terminal-start-failed` followed by the rollback of what the command
/// made (keyed by its `mutation_id`).
///
/// Chromium shows a new tab before its renderer process runs: `ChildProcessLauncher` launches on the
/// launcher thread and tells its client `OnProcessLaunched` or `OnProcessLaunchFailed`
/// (content/browser/child_process_launcher.h). Here the reply ends the command's work and this
/// watch carries the launch's answer to a follow-up that only reports a failure. Open it before the
/// command goes out (``init(_:on:)``): the outcome can come right after the reply.
public final class TerminalStartWatch: Sendable {
    /// The terminal the command names (its caller-chosen `terminal_id`).
    public let terminal: TerminalID
    private let subscription: DaemonEventSubscription
    /// The longest the watch waits for an outcome: the start deadline a synchronous create has.
    private let bound: Duration
    private let clock: any Clock<Duration>

    init(terminal: TerminalID, subscription: DaemonEventSubscription, bound: Duration, clock: any Clock<Duration>) {
        self.terminal = terminal
        self.subscription = subscription
        self.bound = bound
        self.clock = clock
    }

    /// Opens the watch of `terminal`'s start on `connection`, before the command that names it goes
    /// out. Its inbox holds only the events about this terminal that can end its start
    /// (``concerns(_:terminal:)``), so other terminals' events never fill it.
    ///
    /// - Parameters:
    ///   - terminal: The caller-chosen `terminal_id` the command sends.
    ///   - connection: The connection that carries the command; its start deadline bounds the watch.
    public convenience init(_ terminal: TerminalID, on connection: DaemonConnection) {
        let filter = DaemonEventFilter { TerminalStartWatch.concerns($0, terminal: terminal) }
        self.init(terminal: terminal, subscription: connection.subscribe(filter: filter, limit: Self.inboxLimit),
                  bound: connection.configuration.spawnTimeout, clock: connection.clock)
    }

    deinit {
        subscription.cancel()
    }

    /// One terminal's start ends after at most a few of its own events (the outcome, its tab's,
    /// pane's or workspace's close, a drop).
    static let inboxLimit = 8

    /// The `event` names of the start's two outcomes.
    static let startedEvent = "terminal-started"
    static let failedEvent = "terminal-start-failed"

    /// How the start ended, for a reply that said `starting: true`. Ends the watch.
    ///
    /// - Returns: The outcome; ``TerminalStartOutcome/unknown`` when the connection dropped or no
    ///   outcome came within the start deadline (the next snapshot shows whether the terminal is there).
    public func outcome() async -> TerminalStartOutcome {
        let subscription = subscription, bound = bound, clock = clock
        // task-owner: this call; the deadline ends the subscription (the wait below then ends as unknown), cancelled when an outcome comes first
        let deadline = Task {
            // wakeup-allow: the start's one deadline (spawnTimeout, a flexible never-early wait); cancelled when the start ends first
            guard (try? await clock.sleep(for: bound, tolerance: WakeLeeway.window(delay: bound).tolerance)) != nil else { return }
            subscription.cancel()
        }
        defer {
            deadline.cancel()
            subscription.cancel()
        }
        return await Self.firstOutcome(in: subscription, terminal: terminal)
    }

    /// Ends the watch without an outcome (the command failed, or its reply needs none).
    public func cancel() {
        subscription.cancel()
    }

    private static func firstOutcome(in subscription: DaemonEventSubscription, terminal: TerminalID) async -> TerminalStartOutcome {
        for await item in subscription {
            guard case .event(let envelope) = item else { return .unknown } // fell behind: the outcome is gone
            if let outcome = outcome(of: envelope.event, terminal: terminal) { return outcome }
        }
        return .unknown
    }

    /// Whether `event` is about `terminal` and can end its start: its `terminal-started` or
    /// `terminal-start-failed`, the close of its tab, its pane or its workspace, or a drop. Only these
    /// reach the watch's inbox.
    static func concerns(_ event: DaemonEvent, terminal: TerminalID) -> Bool {
        func holds(_ tabs: [TabSnapshot]) -> Bool {
            tabs.contains { $0.terminalID.map { same($0.rawValue, terminal) } ?? false }
        }
        switch event {
        case .unknown(let name, let payload):
            guard name == startedEvent || name == failedEvent, let named = payload["terminal_id"]?.stringValue else { return false }
            return same(named, terminal)
        case .tabClosed(let delta):
            return holds([delta.entity])
        case .paneClosed(let delta):
            return holds(delta.entity.tabs)
        case .workspaceClosed(let delta):
            return delta.entity.screens.contains { $0.panes.contains { holds($0.tabs) } }
        case .disconnected:
            return true
        default:
            return false
        }
    }

    /// The outcome an event the filter let in for `terminal` (``concerns(_:terminal:)``) gives its start.
    static func outcome(of event: DaemonEvent, terminal: TerminalID) -> TerminalStartOutcome? {
        switch event {
        case .unknown(let name, let payload):
            if name == startedEvent { return .started }
            guard name == failedEvent else { return nil }
            return .failed(TerminalStartFailure(terminal: terminal, reason: payload["error"]?.stringValue))
        case .tabClosed, .paneClosed, .workspaceClosed:
            // The person closed it, or the daemon's rollback after a failure it reported first.
            return .closed
        case .disconnected:
            return .unknown
        default:
            return nil
        }
    }

    /// The daemon names a terminal in canonical 32-hex form; a caller id may carry dashes or capitals.
    private static func same(_ named: String, _ terminal: TerminalID) -> Bool {
        canonical(named) == canonical(terminal.rawValue)
    }

    private static func canonical(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// How a terminal start that a command's reply left running ended (``TerminalStartWatch``).
public enum TerminalStartOutcome: Sendable, Equatable {
    /// The host is up; the attached view gets its READY.
    case started
    /// The host did not start; the daemon removes what the command made.
    case failed(TerminalStartFailure)
    /// The terminal's tab, pane or workspace closed before the start ended.
    case closed
    /// The connection dropped, or no outcome came within the start deadline.
    case unknown

    /// The failure, when the start failed.
    public var failure: TerminalStartFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

/// A terminal whose host the daemon could not start after it answered the command that made it
/// (`terminal-start-failed`); the daemon rolled back what that command made.
public struct TerminalStartFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// The terminal that did not start.
    public let terminal: TerminalID
    /// The daemon's reason, when it gave one.
    public let reason: String?

    public init(terminal: TerminalID, reason: String?) {
        self.terminal = terminal
        self.reason = reason
    }

    public var description: String {
        reason.map { "the terminal did not start: \($0)" } ?? "the terminal did not start"
    }
}
