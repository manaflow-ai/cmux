import Foundation
import os

/// Records a device's connectivity events for its signed-in audience.
///
/// Code that sees a connection step calls ``record(_:)`` (from any thread, no waiting): the
/// policy (``ConnectivityPolicy``) decides, under a short lock, what is kept for the current
/// ``ConnectivityAudience``, and one drain task hands each kept record, in order, to the
/// journal and the app's sinks (os log; Sentry on the Mac). The app sets the audience from the
/// signed-in account with ``setAccount(email:)``; a change of audience resets sampling, and any
/// audience other than ``ConnectivityAudience/team`` clears a journal holding team records, so
/// a later account (in this launch or the next) never reads the team's detail.
///
/// The message stream is unbounded on purpose: a dropped flush or audience message would hang a
/// waiter or keep team detail; the sinks are synchronous and cheap (a file append, a log line, a
/// Sentry breadcrumb), and everyone's records are budgeted.
public final class ConnectivityTelemetry: Sendable {
    /// The process's recorder. Apps configure it once at launch (``setJournal(_:)``,
    /// ``addSink(_:)``) and follow the account (``setAccount(email:)``).
    public static let shared = ConnectivityTelemetry()

    /// One kept record, delivered on the drain task.
    public typealias Sink = @Sendable (ConnectivityRecord) -> Void

    private enum Message: Sendable {
        case record(ConnectivityRecord)
        /// The audience is now this; leaving the team clears a journal that holds team records.
        case audience(ConnectivityAudience)
        case journal(ConnectivityJournal?)
        case sink(Sink)
        case flush(CheckedContinuation<Void, Never>)
    }

    private struct State: Sendable {
        var audience: ConnectivityAudience = .everyone
        var policy: ConnectivityPolicy
    }

    // lint:allow lock - record() is synchronous from any thread; the region only runs the pure
    // policy, reads the audience and yields to the stream, never I/O.
    private let state: OSAllocatedUnfairLock<State>
    private let messages: AsyncStream<Message>.Continuation
    /// Timings sent to the Cloud service (``stat(_:)``); follows this recorder's audience.
    public let stats: ConnectivityStats

    public init(configuration: ConnectivityPolicy.Configuration = ConnectivityPolicy.Configuration(),
                stats: ConnectivityStats = ConnectivityStats()) {
        self.stats = stats
        state = OSAllocatedUnfairLock(initialState: State(policy: ConnectivityPolicy(configuration: configuration)))
        let (stream, continuation) = AsyncStream<Message>.makeStream()
        messages = continuation
        // task-owner: the recorder's drain; ends when the recorder is released.
        Task.detached(priority: .utility) {
            var journal: ConnectivityJournal?
            var sinks: [Sink] = []
            for await message in stream {
                switch message {
                case .record(let record):
                    journal?.append(record)
                    for sink in sinks { sink(record) }
                case .audience(let audience):
                    if audience != .team, let journal, journal.holdsTeamRecords() { journal.clear() }
                case .journal(let next):
                    journal = next
                case .sink(let sink):
                    sinks.append(sink)
                case .flush(let done):
                    done.resume()
                }
            }
        }
    }

    deinit { messages.finish() }

    /// The audience records are kept for now.
    public var audience: ConnectivityAudience {
        state.withLock { $0.audience }
    }

    /// Follows the signed-in account: its email's audience (``ConnectivityAudience/init(email:)``),
    /// nil when signed out. A different audience resets sampling; any audience but the team
    /// clears a journal that holds team records.
    public func setAccount(email: String?) {
        setAudience(ConnectivityAudience(email: email))
    }

    /// Sets the audience directly (tests, a forced debug override).
    public func setAudience(_ next: ConnectivityAudience) {
        let messages = messages
        stats.setAudience(next)
        state.withLock { state in
            if state.audience != next {
                state.audience = next
                state.policy.reset()
            }
        // Yielded under the lock, after every record admitted for the earlier audience, so a
        // team record never reaches the journal after the clear. Not team: the drain clears a
        // journal still holding team records (also one a team account left at the last quit).
        // Everyone's records hold no free text, so a team sign-in keeps the history before it.
            if next != .team { messages.yield(.audience(next)) }
        }
    }

    /// Where kept records are written on this device; nil writes none.
    public func setJournal(_ journal: ConnectivityJournal?) {
        messages.yield(.journal(journal))
    }

    /// Adds a sink for every later kept record.
    public func addSink(_ sink: @escaping Sink) {
        messages.yield(.sink(sink))
    }

    /// Records one step. Returns at once; the record (if kept) reaches the journal and sinks on
    /// the drain task.
    public func record(_ event: ConnectivityEvent) {
        let messages = messages
        // Yielded under the lock (a yield to an unbounded stream never waits): see setAudience.
        state.withLock { state in
            if let record = state.policy.admit(event, audience: state.audience) { messages.yield(.record(record)) }
        }
    }

    /// Records one step (``ConnectivityEvent/init(_:_:outcome:fields:detail:date:)``).
    public func record(_ area: ConnectivityEvent.Area, _ name: String, outcome: ConnectivityEvent.Outcome = .info,
                       fields: [String: ConnectivityEvent.Value] = [:], detail: String? = nil) {
        record(ConnectivityEvent(area, name, outcome: outcome, fields: fields, detail: detail))
    }

    /// Records one timing: a local record (journal, sinks) and a stat for the Cloud service.
    public func stat(_ stat: ConnectivityStat) {
        var fields = stat.fields
        if let ms = stat.ms { fields["ms"] = .number(ms) }
        let outcome: ConnectivityEvent.Outcome = switch stat.outcome {
        case .success: .success
        case .failure: .failure
        case .cancelled: .info
        }
        record(ConnectivityEvent(Self.area(of: stat.name), "stat_\(stat.name.rawValue)", outcome: outcome,
                                 fields: fields, date: stat.date))
        stats.add(stat)
    }

    static func area(of name: ConnectivityStat.Name) -> ConnectivityEvent.Area {
        switch name {
        case .macConnect, .reconnect, .sessionEnd, .tabOpen, .linkFailure: .link
        case .hubReady: .hub
        case .pairing: .pairing
        case .cloudLink: .cloudLink
        }
    }

    /// Waits until every message sent before it reached the journal and sinks.
    public func flush() async {
        await withCheckedContinuation { continuation in
            messages.yield(.flush(continuation))
        }
    }

    /// A sink writing each record to the unified log under `subsystem`, category
    /// `connectivity`. The team's records are public, so Console and a sysdiagnose show them
    /// unredacted; everyone's carry only fixed-vocabulary fields.
    public static func unifiedLogSink(subsystem: String) -> Sink {
        let logger = Logger(subsystem: subsystem, category: "connectivity")
        return { record in
            let line = record.summary
            switch record.outcome {
            case .failure: logger.error("\(record.audience.rawValue, privacy: .public) \(line, privacy: .public)")
            case .info, .success: logger.info("\(record.audience.rawValue, privacy: .public) \(line, privacy: .public)")
            }
        }
    }
}
