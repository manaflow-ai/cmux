import Foundation

/// One connectivity timing for the team's dashboards: how long a step took, how it ended and a
/// few fixed words about it (``ConnectivityStats`` sends them to the Cloud service, which logs one
/// line per stat). The names are the service's allowlist (`POST /v1/telemetry/connectivity`).
public struct ConnectivityStat: Sendable, Equatable {
    /// What was timed.
    public enum Name: String, Sendable, Equatable, CaseIterable {
        /// From the start of a connect (launch, foreground, a picked Mac, a retry) until the link
        /// to the Mac is up, or the attempt gave up.
        case macConnect = "mac_connect"
        /// From a link that was up going down until it is up again.
        case reconnect
        /// One connection's life: from up to down, with why it ended.
        case sessionEnd = "session_end"
        /// From opening a tab until it shows its first real content.
        case tabOpen = "tab_open"
        /// From the link coming up until the agent hub has its sessions.
        case hubReady = "hub_ready"
        /// From a pairing request until the phone is paired or refused.
        case pairing
        /// The Mac's link to the Cloud app server coming up.
        case cloudLink = "cloud_link"
        /// A failed dial, with its cause.
        case linkFailure = "link_failure"
    }

    /// How the timed step ended.
    public enum Outcome: String, Sendable, Equatable {
        case success
        case failure
        /// Stopped before it finished (the tab was closed, a newer connect replaced it).
        case cancelled
    }

    public var date: Date
    public var name: Name
    public var outcome: Outcome
    /// The duration in milliseconds, nil when the stat is a count only.
    public var ms: Double?
    /// Fixed words, numbers and flags for everyone; ``ConnectivityEvent/Value/text`` values
    /// reach only the team (as `detail`).
    public var fields: [String: ConnectivityEvent.Value]

    public init(_ name: Name, outcome: Outcome, ms: Double?, fields: [String: ConnectivityEvent.Value] = [:],
                date: Date = Date()) {
        self.date = date
        self.name = name
        self.outcome = outcome
        self.ms = ms.map { $0.isFinite ? max(0, $0.rounded()) : 0 }
        self.fields = fields
    }

    /// The stat as one element of the service's `stats` array. Everyone's stat keeps only fixed
    /// vocabulary under keys that are words; the team's also carries its text values as `detail`.
    func wire(for audience: ConnectivityAudience) -> [String: Any] {
        var fixed: [String: Any] = [:]
        var detail: [String: String] = [:]
        for (key, value) in fields where ConnectivityEvent.Value.isSafeKey(key) {
            switch value {
            case .code(let code): fixed[key] = code
            case .number(let number) where number.isFinite: fixed[key] = number
            case .number: break
            case .flag(let flag): fixed[key] = flag
            case .text(let text) where audience == .team: detail[key] = String(text.prefix(200))
            case .text: break
            }
        }
        var out: [String: Any] = [
            "t": date.formatted(Self.timestamp),
            "name": name.rawValue,
            "outcome": outcome.rawValue,
        ]
        if let ms { out["ms"] = ms }
        if !fixed.isEmpty { out["fields"] = fixed }
        if !detail.isEmpty { out["detail"] = detail }
        return out
    }

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Times one step on the monotonic clock: start it where the step starts, read
/// ``elapsedMilliseconds`` where it ends.
public struct ConnectivityStopwatch: Sendable, Equatable {
    public let start: ContinuousClock.Instant

    public init(start: ContinuousClock.Instant = ContinuousClock.now) {
        self.start = start
    }

    /// Milliseconds since ``start``, rounded.
    public var elapsedMilliseconds: Double {
        elapsedMilliseconds(at: ContinuousClock.now)
    }

    public func elapsedMilliseconds(at now: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: now)
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return max(0, ms.rounded())
    }
}

/// Times one tab from its open until its first real content (`tab_open`): start it where the
/// tab starts loading, call ``finish(_:fields:)`` once where it first shows live content (later
/// calls do nothing). `kind` is the tab's kind (terminal, agent, browser, chief); `cached` says
/// whether something kept from before (a last frame, a kept transcript) was on screen meanwhile.
public struct ConnectivityTabTimer: Sendable {
    public let kind: String
    public let cached: Bool
    public let watch: ConnectivityStopwatch

    public init(kind: String, cached: Bool, start: ContinuousClock.Instant = ContinuousClock.now) {
        self.kind = kind
        self.cached = cached
        watch = ConnectivityStopwatch(start: start)
    }

    /// Records the stat. Callers keep the timer optional and nil it after finishing.
    public func finish(_ outcome: ConnectivityStat.Outcome = .success, fields: [String: ConnectivityEvent.Value] = [:],
                       telemetry: ConnectivityTelemetry = .shared) {
        var all = fields
        all["kind"] = .code(kind)
        all["cached"] = .flag(cached)
        telemetry.stat(ConnectivityStat(.tabOpen, outcome: outcome, ms: watch.elapsedMilliseconds, fields: all))
    }
}
