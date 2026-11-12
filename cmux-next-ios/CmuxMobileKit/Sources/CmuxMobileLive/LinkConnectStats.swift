import CmuxConnectivityTelemetry
import CmuxMobileTransport
import Foundation

/// Turns the link's phase changes into timing stats (``ConnectivityStat``): how long a connect
/// to the Mac took (`mac_connect`), how long a dropped link took to come back (`reconnect`), and
/// how long each connection lasted and why it ended (`session_end`). Pure: the controller feeds
/// it every phase change with the event that caused it and the time, and records what it answers.
struct LinkConnectStats {
    /// What started a connect, as a fixed word.
    enum Trigger: String, Equatable {
        /// The first connect of this launch.
        case launch
        /// A Mac was picked (or the selected one changed).
        case pick
        /// The app came back to the foreground.
        case foreground
        /// The phone's network changed or came back.
        case network
        /// The link dropped or stopped answering.
        case drop
        /// The Mac came back online.
        case macOnline = "mac_online"
        /// A debug transport or relay setting changed.
        case setting
        case other
    }

    private struct Attempt {
        var started: ContinuousClock.Instant
        var trigger: Trigger
        var attempts = 1
        var failures = 0
        var lastFailure: String?
    }

    private var attempt: Attempt?
    /// The link that was up went down here (and why), until it is up again.
    private var down: (at: ContinuousClock.Instant, cause: String)?
    private var connectedSince: ContinuousClock.Instant?
    private var connectedOnce = false

    /// The trigger a phase change caused by `event` gets.
    static func trigger(_ event: LinkMachine.Event, connectedOnce: Bool) -> Trigger {
        switch event {
        case .target: connectedOnce ? .pick : .launch
        case .foreground, .resume: .foreground
        case .networkChanged: .network
        case .linkDropped, .probeFailed: .drop
        case .macSignaled: .macOnline
        case .transport, .relayOnly, .blockUDP: .setting
        default: connectedOnce ? .other : .launch
        }
    }

    /// Why a connection that was up ended, as a fixed word.
    static func endCause(_ event: LinkMachine.Event, to new: LinkMachine.Phase) -> String {
        if new == .macOffline { return "mac_offline" }
        if new == .signedOut { return "signed_out" }
        switch event {
        case .linkDropped: "dropped"
        case .probeFailed: "probe_failed"
        case .background: "background"
        case .resume, .foreground: "resume"
        case .networkChanged: "network_changed"
        case .target(.none): "closed"
        case .target: "target_changed"
        case .transport, .relayOnly, .blockUDP: "setting"
        default: "other"
        }
    }

    /// A path as the service's code: lowercase snake_case (`turn_tls`, `no_path`).
    static func code(_ path: LinkPathKind) -> String {
        switch path {
        case .direct: "direct"
        case .turn: "turn"
        case .turnTLS: "turn_tls"
        case .noPath: "no_path"
        }
    }

    /// The stats one phase change ends, at `now`.
    mutating func change(from old: LinkMachine.Phase, to new: LinkMachine.Phase, by event: LinkMachine.Event,
                         at now: ContinuousClock.Instant, date: Date = Date()) -> [ConnectivityStat] {
        var stats: [ConnectivityStat] = []
        // A connection ended: its life, and the outage that starts now.
        if case .connected(let transport, let path, _) = old, !new.isConnected {
            let cause = Self.endCause(event, to: new)
            var fields: [String: ConnectivityEvent.Value] = [
                "cause": .code(cause), "transport": .code(transport.rawValue), "path": .code(Self.code(path)),
            ]
            if case .linkDropped(_, let reason) = event { fields["reason"] = .text(reason) }
            if case .probeFailed(_, let reason) = event { fields["reason"] = .text(reason) }
            let lived = connectedSince.map { ConnectivityStopwatch(start: $0).elapsedMilliseconds(at: now) }
            stats.append(ConnectivityStat(.sessionEnd, outcome: .success, ms: lived, fields: fields, date: date))
            connectedSince = nil
            // Leaving on purpose (background, a closed or changed target) is no outage.
            if ["dropped", "probe_failed", "network_changed", "resume", "mac_offline"].contains(cause) { down = (now, cause) }
        }
        switch new {
        case .connecting(_, let number):
            if attempt == nil {
                attempt = Attempt(started: now, trigger: Self.trigger(event, connectedOnce: connectedOnce))
            }
            attempt?.attempts = max(attempt?.attempts ?? 1, number)
        case .waiting(_, _, let reason, _):
            if attempt == nil { attempt = Attempt(started: now, trigger: Self.trigger(event, connectedOnce: connectedOnce)) }
            attempt?.failures += 1
            attempt?.lastFailure = reason
        case .connected(let transport, let path, let rtt):
            guard !old.isConnected else { break }
            var fields: [String: ConnectivityEvent.Value] = ["transport": .code(transport.rawValue), "path": .code(Self.code(path))]
            if let rtt { fields["rtt_ms"] = .number(Double(rtt)) }
            if let attempt {
                var connect = fields
                connect["trigger"] = .code(attempt.trigger.rawValue)
                connect["attempts"] = .number(Double(attempt.attempts))
                connect["failures"] = .number(Double(attempt.failures))
                connect["first_of_launch"] = .flag(!connectedOnce)
                if let failure = attempt.lastFailure { connect["last_failure"] = .text(failure) }
                stats.append(ConnectivityStat(.macConnect, outcome: .success,
                                              ms: ConnectivityStopwatch(start: attempt.started).elapsedMilliseconds(at: now),
                                              fields: connect, date: date))
            }
            if let down {
                var back = fields
                back["cause"] = .code(down.cause)
                stats.append(ConnectivityStat(.reconnect, outcome: .success,
                                              ms: ConnectivityStopwatch(start: down.at).elapsedMilliseconds(at: now),
                                              fields: back, date: date))
            }
            attempt = nil
            down = nil
            connectedSince = now
            connectedOnce = true
        case .idle, .macOffline, .signedOut:
            // The connect ends without a link: the Mac went offline, the session was revoked,
            // or nothing is selected any more (cancelled).
            let outcome: ConnectivityStat.Outcome = new == .idle ? .cancelled : .failure
            let cause = new == .idle ? "closed" : new == .signedOut ? "signed_out" : "mac_offline"
            if let attempt {
                var fields: [String: ConnectivityEvent.Value] = [
                    "trigger": .code(attempt.trigger.rawValue), "attempts": .number(Double(attempt.attempts)),
                    "failures": .number(Double(attempt.failures)), "cause": .code(cause),
                    "first_of_launch": .flag(!connectedOnce),
                ]
                if let failure = attempt.lastFailure { fields["last_failure"] = .text(failure) }
                stats.append(ConnectivityStat(.macConnect, outcome: outcome,
                                              ms: ConnectivityStopwatch(start: attempt.started).elapsedMilliseconds(at: now),
                                              fields: fields, date: date))
            }
            if let down, new != .macOffline {
                stats.append(ConnectivityStat(.reconnect, outcome: outcome,
                                              ms: ConnectivityStopwatch(start: down.at).elapsedMilliseconds(at: now),
                                              fields: ["cause": .code(down.cause), "ended_by": .code(cause)], date: date))
                self.down = nil
            }
            attempt = nil
        }
        return stats
    }

    /// The app went to the background with a connect in flight: that attempt ends, cancelled.
    mutating func backgrounded(at now: ContinuousClock.Instant, date: Date = Date()) -> [ConnectivityStat] {
        guard let attempt else { return [] }
        self.attempt = nil
        return [ConnectivityStat(.macConnect, outcome: .cancelled,
                                 ms: ConnectivityStopwatch(start: attempt.started).elapsedMilliseconds(at: now),
                                 fields: ["trigger": .code(attempt.trigger.rawValue), "attempts": .number(Double(attempt.attempts)),
                                          "failures": .number(Double(attempt.failures)), "cause": .code("background"),
                                          "first_of_launch": .flag(!connectedOnce)],
                                 date: date)]
    }

    var hasConnected: Bool { connectedOnce }
}
