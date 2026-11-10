import Foundation
#if canImport(os)
import os
#endif

/// Records a device's connectivity events for its signed-in audience.
///
/// Code that sees a connection step calls ``record(_:)`` (from any thread, no waiting): the
/// policy (``ConnectivityPolicy``) decides, under a short lock, what is kept for the current
/// ``ConnectivityAudience``, and one drain task hands each kept record, in order, to the
/// journal and the app's sinks (os log; Sentry on the Mac). The app sets the audience from the
/// signed-in account with ``setAccount(email:)``; a change of audience resets sampling, and
/// leaving ``ConnectivityAudience/team`` clears the journal, so a later account never reads
/// the team's detail.
public final class ConnectivityTelemetry: @unchecked Sendable {
    /// The process's recorder. Apps configure it once at launch (``setJournal(_:)``,
    /// ``addSink(_:)``) and follow the account (``setAccount(email:)``).
    public static let shared = ConnectivityTelemetry()

    /// One kept record, delivered on the drain task.
    public typealias Sink = @Sendable (ConnectivityRecord) -> Void

    private enum Message: Sendable {
        case record(ConnectivityRecord)
        case clear
        case journal(ConnectivityJournal?)
        case sink(Sink)
        case flush(CheckedContinuation<Void, Never>)
    }

    private struct State {
        var audience: ConnectivityAudience = .everyone
        var policy: ConnectivityPolicy
    }

    // lint:allow lock - record() is synchronous from any thread; the region only runs the pure
    // policy and reads the audience, never I/O.
    private let lock = NSLock()
    private var state: State
    private let messages: AsyncStream<Message>.Continuation

    public init(configuration: ConnectivityPolicy.Configuration = ConnectivityPolicy.Configuration()) {
        state = State(policy: ConnectivityPolicy(configuration: configuration))
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
                case .clear:
                    journal?.clear()
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
        lock.lock()
        defer { lock.unlock() }
        return state.audience
    }

    /// Follows the signed-in account: its email's audience (``ConnectivityAudience/init(email:)``),
    /// nil when signed out. A different audience resets sampling; leaving the team clears the journal.
    public func setAccount(email: String?) {
        setAudience(ConnectivityAudience(email: email))
    }

    /// Sets the audience directly (tests, a forced debug override).
    public func setAudience(_ next: ConnectivityAudience) {
        lock.lock()
        let previous = state.audience
        if previous != next {
            state.audience = next
            state.policy.reset()
        }
        lock.unlock()
        // The team's detail never stays for a later account; everyone's records hold none, so
        // a team sign-in (each launch, once auth resolves) keeps the history before it.
        if previous == .team, next != .team { messages.yield(.clear) }
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
        lock.lock()
        let record = state.policy.admit(event, audience: state.audience)
        lock.unlock()
        if let record { messages.yield(.record(record)) }
    }

    /// Records one step (``ConnectivityEvent/init(_:_:outcome:fields:detail:date:)``).
    public func record(_ area: ConnectivityEvent.Area, _ name: String, outcome: ConnectivityEvent.Outcome = .info,
                       fields: [String: ConnectivityEvent.Value] = [:], detail: String? = nil) {
        record(ConnectivityEvent(area, name, outcome: outcome, fields: fields, detail: detail))
    }

    /// Waits until every message sent before it reached the journal and sinks.
    public func flush() async {
        await withCheckedContinuation { continuation in
            messages.yield(.flush(continuation))
        }
    }

    #if canImport(os)
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
    #endif
}
