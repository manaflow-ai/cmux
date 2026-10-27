import Foundation

/// The start of one terminal that a daemon with `terminal-async-start-v1` admitted before its host
/// was up (F10, p05-ipc-130): the command's reply says `starting: true`, and the daemon reports the
/// host's launch on the control sequence as `terminal-started`, or as `terminal-start-failed`
/// followed by the rollback of what the command made (keyed by its `mutation_id`).
///
/// Chromium shows a new tab before its renderer process runs: `ChildProcessLauncher` launches on the
/// launcher thread and tells its client `OnProcessLaunched` or `OnProcessLaunchFailed`
/// (content/browser/child_process_launcher.h), and the client never times the launch itself. Here
/// the reply settles the stand-in and this watch carries the launch's answer to the action that
/// made it. Open it before the command goes out (``init(_:on:)``): the
/// outcome can come right after the reply.
public final class TerminalStartWatch: Sendable {
    /// The terminal the command names (its caller-chosen `terminal_id`).
    public let terminal: TerminalID
    private let subscription: DaemonEventSubscription

    init(terminal: TerminalID, subscription: DaemonEventSubscription) {
        self.terminal = terminal
        self.subscription = subscription
    }

    /// Opens the watch of `terminal`'s start on `connection`, before the command that names it goes
    /// out. Its inbox holds only the events that can end a start (``mayEnd(_:)``).
    ///
    /// - Parameters:
    ///   - terminal: The caller-chosen `terminal_id` the command sends.
    ///   - connection: The connection that carries the command.
    public convenience init(_ terminal: TerminalID, on connection: DaemonConnection) {
        let filter = DaemonEventFilter { TerminalStartWatch.mayEnd($0) }
        self.init(terminal: terminal, subscription: connection.subscribe(filter: filter, limit: 64))
    }

    deinit {
        subscription.cancel()
    }

    /// The `event` names of the start's two outcomes.
    static let startedEvent = "terminal-started"
    static let failedEvent = "terminal-start-failed"

    /// How the start of `created`'s terminal ended. A reply without `starting` (a daemon that answers
    /// after the start) is ``TerminalStartOutcome/started`` at once. Ends the watch.
    ///
    /// - Parameter created: The reply of the command the watch was opened for.
    /// - Returns: The outcome; ``TerminalStartOutcome/unknown`` when the connection dropped or ended
    ///   first (the next snapshot shows whether the terminal is there).
    public func outcome(of created: SurfaceCreated) async -> TerminalStartOutcome {
        defer { subscription.cancel() }
        guard created.starting == true else { return .started }
        for await item in subscription {
            guard case .event(let envelope) = item else { return .unknown } // fell behind: the outcome is gone
            if let outcome = Self.outcome(of: envelope.event, terminal: terminal, surface: created.surface) { return outcome }
        }
        return .unknown
    }

    /// Ends the watch without an outcome (the command failed, or its reply needs none).
    public func cancel() {
        subscription.cancel()
    }

    /// Whether `event` can end a start: only these reach the watch's inbox.
    static func mayEnd(_ event: DaemonEvent) -> Bool {
        switch event {
        case .unknown(let name, _): name == startedEvent || name == failedEvent
        case .tabClosed, .disconnected: true
        default: false
        }
    }

    /// The outcome `event` gives the start of `terminal`, shown as `surface`, or nil when it says
    /// nothing about it.
    static func outcome(of event: DaemonEvent, terminal: TerminalID, surface: SurfaceID) -> TerminalStartOutcome? {
        switch event {
        case .unknown(let name, let payload):
            guard payload["terminal_id"]?.stringValue == terminal.rawValue else { return nil }
            if name == startedEvent { return .started }
            guard name == failedEvent else { return nil }
            return .failed(TerminalStartFailure(terminal: terminal, reason: payload["error"]?.stringValue))
        case .tabClosed(let delta):
            // The person closed the tab, or the daemon's rollback after a failure it reported first.
            return delta.surface == surface ? .closed : nil
        case .disconnected:
            return .unknown
        default:
            return nil
        }
    }
}

/// How a terminal start that a command's reply left running ended (``TerminalStartWatch``).
public enum TerminalStartOutcome: Sendable, Equatable {
    /// The host is up; the attached view gets its READY.
    case started
    /// The host did not start; the daemon removes what the command made.
    case failed(TerminalStartFailure)
    /// The tab closed before the start ended.
    case closed
    /// The connection dropped or the watch fell behind first.
    case unknown
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
