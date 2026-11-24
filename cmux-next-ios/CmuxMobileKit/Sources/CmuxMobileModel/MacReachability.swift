import Foundation

/// Why this phone's last try at a Mac failed, as far as the phone can tell (cmux#52200). Each
/// says how far the try got: the Mac never answered, or it answered and cmux on it did not.
public enum MacLinkFailure: Equatable, Sendable {
    /// The phone dialed (through the cmux service's relay or directly) and the Mac never answered.
    case hostUnreachable
    /// The link to the Mac opened, but cmux on it (its daemon) did not answer or sent no workspaces.
    case serviceDown
    /// The cmux service refused this account's session.
    case authRequired
    /// The Mac refused this iPhone.
    case notAllowed
    /// Tailscale only: the dial could not use the tailnet, and why.
    case tailscale(TailscaleProblem)
}

/// Why a Tailscale-only dial could not reach a Mac (PROTOCOL.md "Tailscale-only links").
public enum TailscaleProblem: Equatable, Sendable {
    /// The Tailscale app is off or not connected on this iPhone.
    case phoneOff
    /// Tailscale is not running on the Mac.
    case macOff
    /// The Mac is on the tailnet, but its address did not answer.
    case unreachable
    /// The Mac never answered the dial: an older cmux on it, or it is asleep.
    case noAnswer
    /// The cmux service does not relay the dial yet.
    case unsupported
}

/// What a Mac's own view says about it: the presence the cmux service reports, this phone's
/// link to it and the last failure, in one state with copy that says what to do next.
/// Leo, 2026-11-23: "Cosmic Gray appears offline on my iOS phone. I cannot access or revive the
/// computer from iOS. I need that to be recoverable."
public enum MacReachability: Equatable, Sendable {
    case connected
    case connecting
    /// Online, the link is not on it (another Mac is linked): Connect moves it here.
    case notConnected
    /// The service lists it online but has not heard its heartbeat for this long: overloaded,
    /// or its network is failing. The link is not up.
    case slow(quietSeconds: Int)
    /// The service says it is offline (its signaling socket closed); nothing dialed it since.
    case offline(lastSeenAt: Date?)
    /// This phone dialed it and it never answered. `listedOnline`: what the service said.
    case noAnswer(listedOnline: Bool, lastSeenAt: Date?)
    /// The Mac answered; cmux on it did not.
    case serviceDown
    case authRequired
    case notAllowed
    /// Tailscale only: the tailnet could not carry the dial.
    case tailscale(TailscaleProblem)
    /// This iPhone has no network: nothing about the Mac is known.
    case phoneOffline

    /// The service's freshness bound (`FRESH_MS` in backend/src/team-hub.ts): a Mac pings every
    /// 15 s, so one quiet longer than this missed a heartbeat.
    public static let freshMillis = 18_000

    /// `quietMs` as ``MacDevice/quietMs`` keeps it: only past the bound, rounded down to 10 s.
    public static func lateQuiet(_ quietMs: Int?) -> Int? {
        guard let quietMs, quietMs > freshMillis else { return nil }
        return quietMs / 10_000 * 10_000
    }

    /// - `connection`: this phone's link (nil: not linked). `live`: false in mock mode, where
    ///   presence alone decides. `phoneOffline`: the device has no network.
    public static func resolve(mac: MacDevice, connection: MacConnection?, failure: MacLinkFailure?,
                               live: Bool, phoneOffline: Bool = false) -> MacReachability {
        guard live else { return mac.isOnline ? .connected : .offline(lastSeenAt: mac.lastSeenAt) }
        if phoneOffline, connection != .connected { return .phoneOffline }
        switch failure {
        case .authRequired: return .authRequired
        case .notAllowed: return .notAllowed
        case .serviceDown: return .serviceDown
        case .tailscale(let problem) where connection != .connected && connection != .connecting:
            return .tailscale(problem)
        // A Mac the service lists offline is offline, whatever the dial said: its title says so,
        // with when it was last seen (cmux#52200: "<host> is offline" + last seen, not "didn't answer").
        case .hostUnreachable where connection != .connected && connection != .connecting:
            return mac.isOnline ? .noAnswer(listedOnline: true, lastSeenAt: mac.lastSeenAt) : .offline(lastSeenAt: mac.lastSeenAt)
        default: break
        }
        switch connection {
        case .connected: return .connected
        case .connecting: return .connecting
        case .failed, nil: break
        }
        guard mac.isOnline else { return .offline(lastSeenAt: mac.lastSeenAt) }
        if let quiet = mac.quietMs { return .slow(quietSeconds: quiet / 1000) }
        if case .failed = connection { return .noAnswer(listedOnline: true, lastSeenAt: mac.lastSeenAt) }
        return .notConnected
    }

    /// Whether the Mac's view offers Retry: every state the person can try again from.
    public var offersRetry: Bool { action == .retry }

    /// What the Mac's view offers the person in this state: Retry, or Sign In. Nil while it is
    /// connected, or on its way (the view keeps its cached rows and says nothing more).
    public var action: MacRecoveryAction? {
        switch self {
        case .connected, .connecting, .notConnected: nil
        case .authRequired: .signIn
        case .slow, .offline, .noAnswer, .serviceDown, .notAllowed, .phoneOffline, .tailscale: .retry
        }
    }

    /// The SF Symbol of the state.
    public var symbol: String {
        switch self {
        case .connected: "checkmark.circle"
        case .connecting, .notConnected: "link"
        case .slow: "tortoise"
        case .offline: "moon.zzz"
        case .noAnswer: "bolt.horizontal.circle"
        case .serviceDown: "exclamationmark.triangle"
        case .authRequired: "person.crop.circle.badge.exclamationmark"
        case .notAllowed: "hand.raised"
        case .phoneOffline: "wifi.slash"
        case .tailscale: "network.slash"
        }
    }

    /// One short line beside the Mac's name ("Offline · Last seen 50m ago").
    public func statusText(now: Date) -> String {
        switch self {
        case .connected: "Online"
        case .connecting: "Connecting…"
        case .notConnected: "Online · Not connected"
        case .slow(let quiet): "Not responding · heard \(Self.span(quiet)) ago"
        case .offline(let seen): RelativeStamp(now: now).presence(isOnline: false, lastSeenAt: seen)
        case .noAnswer(let online, let seen):
            online ? "Online · Not responding" : RelativeStamp(now: now).presence(isOnline: false, lastSeenAt: seen)
        case .serviceDown: "Reached · cmux not answering"
        case .authRequired: "Signed out"
        case .notAllowed: "Didn't allow this iPhone"
        case .phoneOffline: "This iPhone is offline"
        case .tailscale(.phoneOff): "Tailscale is off on this iPhone"
        case .tailscale(.macOff): "Tailscale is off on the Mac"
        case .tailscale(.unreachable): "Not reachable on your tailnet"
        case .tailscale(.noAnswer): "Didn't answer over Tailscale"
        case .tailscale(.unsupported): "Tailscale Only unavailable"
        }
    }

    public func title(macName: String) -> String {
        switch self {
        case .connected: "\(macName) is connected"
        case .connecting: "Connecting to \(macName)…"
        case .notConnected: "\(macName) isn't connected"
        case .slow: "\(macName) isn't responding"
        case .offline: "\(macName) is offline"
        // Listed online but not answering (frozen, overloaded, a half-open socket): the same words as
        // a Mac whose heartbeat went quiet. A Mac listed offline is offline.
        case .noAnswer(let online, _): online ? "\(macName) isn't responding" : "\(macName) is offline"
        case .serviceDown: "cmux on \(macName) isn't answering"
        case .authRequired: "Sign in again"
        case .notAllowed: "\(macName) didn't allow this iPhone"
        case .phoneOffline: "This iPhone is offline"
        case .tailscale(.phoneOff): "Tailscale isn't connected on this iPhone"
        case .tailscale(.macOff): "Tailscale isn't running on \(macName)"
        case .tailscale(.unreachable): "\(macName) isn't reachable on your tailnet"
        case .tailscale(.noAnswer): "\(macName) didn't answer over Tailscale"
        case .tailscale(.unsupported): "Tailscale Only isn't available yet"
        }
    }

    /// What happened, as far as the phone can tell, and what to do next.
    public func message(macName: String, now: Date) -> String {
        let seen: (Date?) -> String = { date in
            guard let date else { return "" }
            let stamp = RelativeStamp(now: now).presence(isOnline: false, lastSeenAt: date)
            return " " + stamp.prefix(1) + stamp.dropFirst() + "."
        }
        return switch self {
        case .connected: "Your sessions on \(macName) are live."
        case .connecting: "Your sessions on \(macName) stay open while this iPhone connects."
        case .notConnected: "Connect to this Mac to view its workspaces."
        case .slow(let quiet):
            "The cmux service hasn't heard from \(macName) for \(Self.span(quiet)). The Mac may be overloaded or its network failing. Retry, or check the Mac."
        case .offline(let date):
            "The cmux service lost touch with \(macName).\(seen(date)) Retry to try reaching it directly; if it doesn't answer, make sure the Mac is awake and cmux is open."
        case .noAnswer(true, _):
            "The cmux service lists \(macName) as online, but it isn't responding to this iPhone. It may be frozen, busy or overloaded. Retry, or quit and reopen cmux on the Mac."
        case .noAnswer(false, let date):
            "The cmux service lost touch with \(macName).\(seen(date)) The Mac may be asleep, or cmux on it may have quit. Make sure it's awake and cmux is open, then retry."
        case .serviceDown:
            "This iPhone reached \(macName), but cmux on it didn't respond. Your sessions stay on the Mac. Retry, or quit and reopen cmux on the Mac."
        case .authRequired: "The cmux service refused this iPhone's session. Sign in again to reach \(macName)."
        case .notAllowed: "Allow this iPhone on \(macName), then retry."
        case .phoneOffline: "Connect to Wi-Fi or cellular. \(macName) reconnects on its own when the network is back."
        case .tailscale(.phoneOff):
            "Tailscale Only reaches \(macName) through the Tailscale app. Open Tailscale and connect, then retry. To use cmux's own connection instead, turn on Fall back to WireGuard in Settings → Transport."
        case .tailscale(.macOff):
            "\(macName) has no tailnet address. Open Tailscale on the Mac and connect, then retry, or turn on Fall back to WireGuard in Settings → Transport."
        case .tailscale(.unreachable):
            "\(macName) is on a tailnet, but this iPhone couldn't reach it there. Make sure both are on the same tailnet and the Mac is awake, then retry."
        case .tailscale(.noAnswer):
            "\(macName) didn't answer a Tailscale Only connection. Update cmux on the Mac, or make sure it's awake, then retry."
        case .tailscale(.unsupported):
            "The cmux service can't set up Tailscale Only connections yet. Choose WireGuard in Settings → Transport for now."
        }
    }

    /// A few words for the page's subtitle while the Mac's view shows this state in full (the panel
    /// carries the last-seen time and what to do), so the header never truncates mid-sentence.
    public var shortStatus: String {
        switch self {
        case .connected: "Online"
        case .connecting: "Connecting…"
        case .notConnected: "Not connected"
        case .slow, .noAnswer(true, _): "Not responding"
        case .offline, .noAnswer(false, _): "Offline"
        case .serviceDown: "cmux not answering"
        case .authRequired: "Signed out"
        case .notAllowed: "Not allowed"
        case .phoneOffline: "iPhone offline"
        }
    }

    /// "45 s", "3 min", "2 h".
    static func span(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }
}

/// The one thing a Mac's view offers when the phone can't use it.
public enum MacRecoveryAction: Equatable, Sendable {
    case retry
    case signIn
}

/// One Retry from a Mac's view, step by step, so the person sees how far it got (cmux#52200:
/// "A user must know whether a retry reached the host and what to do next").
public struct MacRecoveryAttempt: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Comparable, Sendable {
        /// Asking the cmux service (the relay) for the Mac's presence.
        case service
        /// Dialing the Mac.
        case mac
        /// The link is up; cmux on the Mac sends its workspaces and sessions.
        case session

        public static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        public func label(macName: String) -> String {
            switch self {
            case .service: "Reaching the cmux service"
            case .mac: "Reaching \(macName)"
            case .session: "Opening your sessions"
            }
        }
    }

    public enum Result: Equatable, Sendable {
        case connected
        /// Stopped at this step.
        case failed(Step)
    }

    /// What the link shows while the attempt runs, read by ``advanced(by:)``.
    public enum Observation: Equatable, Sendable {
        case dialing
        /// The link is up; the Mac's workspaces have not come yet.
        case linked
        /// The Mac's workspaces came over the link.
        case live
        case failed(MacLinkFailure)
        /// The dial ended with the Mac offline.
        case offline
    }

    public var step: Step
    public var result: Result?

    public init(step: Step = .service, result: Result? = nil) {
        self.step = step
        self.result = result
    }

    public var isRunning: Bool { result == nil }

    /// What the view offers beside the outcome: Retry once the attempt failed. Nil while it runs
    /// (its steps show how far it got, under a time bound: ``timedOut()``) or once it connected.
    public var action: MacRecoveryAction? {
        if case .failed = result { return .retry }
        return nil
    }

    /// One Retry over several Macs (All Macs): running while any runs, at the furthest step any
    /// reached; connected once one connected; else failed at the furthest step. Nil with none.
    public static func combined(_ attempts: [MacRecoveryAttempt]) -> MacRecoveryAttempt? {
        guard !attempts.isEmpty else { return nil }
        if attempts.contains(where: { $0.result == .connected }) {
            return MacRecoveryAttempt(step: .session, result: .connected)
        }
        let running = attempts.filter(\.isRunning)
        if let furthest = running.map(\.step).max() { return MacRecoveryAttempt(step: furthest) }
        let step = attempts.map(\.step).max() ?? .service
        return MacRecoveryAttempt(step: step, result: .failed(step))
    }

    /// The attempt after the link showed `observation`, once the service step passed.
    public func advanced(by observation: Observation) -> MacRecoveryAttempt {
        guard isRunning, step >= .mac else { return self }
        var next = self
        switch observation {
        case .dialing: break
        case .linked: next.step = .session
        case .live:
            next.step = .session
            next.result = .connected
        // A Tailscale-only dial that the tailnet could not carry never reached the Mac.
        case .offline, .failed(.hostUnreachable), .failed(.tailscale): next.result = .failed(.mac)
        case .failed(.serviceDown): next.result = .failed(.session)
        case .failed(.authRequired), .failed(.notAllowed): next.result = .failed(step)
        }
        return next
    }

    /// The attempt when its deadline passed with no result: failed where it stood.
    public func timedOut() -> MacRecoveryAttempt {
        guard isRunning else { return self }
        return MacRecoveryAttempt(step: step, result: .failed(step))
    }

    /// The line under the steps once the attempt ended: whether it reached the Mac.
    public func outcome(macName: String) -> String? {
        switch result {
        case nil: nil
        case .connected: "Connected. Your sessions are back."
        case .failed(.service): "Couldn't reach the cmux service. Check this iPhone's connection, then retry."
        case .failed(.mac): "Reached the cmux service, but not \(macName). Make sure it's awake and cmux is open, then retry."
        case .failed(.session): "Reached \(macName), but cmux on it isn't responding. Quit and reopen cmux on the Mac, then retry."
        }
    }
}
