public import Foundation

/// What the Chief profile card's Computer tab shows (cmux issue 31488): the Chief's own computer,
/// a Cloud sandbox with a desktop that the Chief works on by sight (`chief-vm computer`, backend
/// chief-brain-cc/sandbox-computer.ts), captioned "<name>'s screen". The tab shows only when the plan pays for cmux Cloud and the Chief has
/// set up a computer at least once; from then on it stays, also while the computer sleeps or is gone.
public struct HomeChiefComputer: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Running: its screen streams.
        case live
        /// Paused, suspended or stopped: not woken for a look.
        case asleep
        /// Starting or resuming.
        case waking
        /// Gone, failed, or the Cloud service did not say.
        case unavailable
    }

    /// The owner's answer of `GET v1/chiefs/<agent>/computer`.
    public struct Status: Equatable, Sendable {
        /// The Chief has set up a computer at least once.
        public var used: Bool
        /// The computer now (its sandbox id and Freestyle state); nil when it has none.
        public var computer: (id: String, state: String)?
        /// The Chief acted on the computer moments ago (the chat's popup).
        public var acting: Bool

        public init(used: Bool, computer: (id: String, state: String)?, acting: Bool = false) {
            self.used = used
            self.computer = computer
            self.acting = acting
        }

        public static func == (a: Status, b: Status) -> Bool {
            a.used == b.used && a.acting == b.acting && a.computer?.id == b.computer?.id && a.computer?.state == b.computer?.state
        }

        /// The route's JSON (`{ok, value: {used, computer: {id, state} | null}}`); nil for anything else.
        public init?(json data: Data) {
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["ok"] as? Bool == true,
                  let value = root["value"] as? [String: Any], let used = value["used"] as? Bool else { return nil }
            let computer = value["computer"] as? [String: Any]
            let id = computer?["id"] as? String
            self.init(used: used, computer: id.map { ($0, computer?["state"] as? String ?? "unknown") }, acting: value["acting"] as? Bool ?? false)
        }
    }

    /// The computer's sandbox id; nil when the Chief has none now.
    public var machineID: String?
    /// "<Chief name>'s screen".
    public var title: String
    public var state: State
    /// The Chief is using it now.
    public var acting: Bool

    public init(machineID: String?, title: String, state: State, acting: Bool = false) {
        self.machineID = machineID
        self.title = title
        self.state = state
        self.acting = acting
    }

    /// The section for `status` (nil hides it): a paid plan and a Chief that has used a computer.
    public init?(status: Status?, paid: Bool, chief: String) {
        guard paid, let status, status.used else { return nil }
        self.init(machineID: status.computer?.id, title: HomeEngineStrings.computerTitle(chief),
                  state: status.computer.map { Self.state(of: $0.state) } ?? .unavailable, acting: status.acting)
    }

    /// Freestyle's VM states (`GET /v5/vms/ID`).
    static func state(of freestyle: String) -> State {
        switch freestyle {
        case "running": .live
        case "paused", "suspended", "suspending", "stopped", "stopping": .asleep
        case "starting", "resuming", "creating", "booting": .waking
        default: .unavailable
        }
    }
}
