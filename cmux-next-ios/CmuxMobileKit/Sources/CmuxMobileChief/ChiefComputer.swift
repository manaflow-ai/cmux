import CmuxMobileBrowserStream
import Foundation
import Observation

/// The Mac the Computer card asks, as the live coordinator picked it: a
/// connected Mac that serves the Cloud directory.
public struct ChiefComputerMac: Equatable, Sendable {
    public var macID: String
    /// The Mac's host streams Cloud desktops (`cloud-desktop-v1`).
    public var streamsDesktop: Bool

    public init(macID: String, streamsDesktop: Bool) {
        self.macID = macID
        self.streamsDesktop = streamsDesktop
    }
}

/// The paired Mac's Cloud directory, as the Computer card reads it (the
/// `cloud-directory` reply: `paid` and each machine's `status` and `ran`).
public struct ChiefComputerDirectory: Equatable, Sendable {
    public struct Machine: Equatable, Sendable {
        public var machineID: String
        public var teamID: String
        public var name: String
        /// The Cloud status (`running`, `paused`, ...); nil when the Mac does not say.
        public var status: String?
        /// The machine has run at least once.
        public var ran: Bool

        public init(machineID: String, teamID: String, name: String, status: String?, ran: Bool) {
            self.machineID = machineID
            self.teamID = teamID
            self.name = name
            self.status = status
            self.ran = ran
        }
    }

    public var paid: Bool
    /// The Mac shows the Cloud machine's screen on phones (`phone.cloudDesktop`, off by default).
    public var desktops: Bool
    public var machines: [Machine]

    public init(paid: Bool, desktops: Bool = true, machines: [Machine]) {
        self.paid = paid
        self.desktops = desktops
        self.machines = machines
    }

    /// The card shows only for an account that pays for cmux Cloud and has
    /// started a machine at least once, from a Mac whose owner turned on
    /// `phone.cloudDesktop`.
    public var showsComputer: Bool { paid && desktops && machines.contains(where: \.ran) }

    /// The machine the card shows: the first running one, else the first one
    /// that has run (directory order); nil when the card is hidden.
    public var computer: Machine? {
        guard showsComputer else { return nil }
        return machines.first { $0.status == "running" } ?? machines.first(where: \.ran)
    }
}

/// What the Computer card shows for its machine.
public enum ChiefComputerState: Equatable, Sendable {
    /// Running: the live, view-only screen.
    case live
    /// Paused or pausing.
    case asleep
    /// Starting or provisioning.
    case waking
    /// Failed, unknown, or a Mac that cannot show it.
    case unavailable

    /// A Cloud status (the `CloudMachine.Status` raw value) as the card's state.
    public init(status: String?) {
        switch status {
        case "running": self = .live
        case "paused", "pausing": self = .asleep
        case "starting", "provisioning": self = .waking
        default: self = .unavailable
        }
    }

    /// The state after the Mac refused (or ended) the screen with `refusal`:
    /// `asleep` means the machine stopped running; a refusal that will not
    /// pass by itself means the screen is not available. Anything else (a
    /// dropped link, a stall) leaves the state; the stream reopens itself.
    public func refused(_ refusal: String?) -> ChiefComputerState {
        guard self == .live, let refusal else { return self }
        switch refusal {
        case "asleep": return .asleep
        case "forbidden", "no_surface_host", "unknown_service", "bad_request", "unavailable": return .unavailable
        default: return self
        }
    }

    /// The card's state row.
    public var title: String {
        switch self {
        case .live: String(localized: "Awake")
        case .asleep: String(localized: "Asleep")
        case .waking: String(localized: "Waking up")
        case .unavailable: String(localized: "Unavailable")
        }
    }
}

/// Where the card reads from: the live coordinator, which knows the
/// connected Macs. Nil (signed out, demo, mock): the card is hidden.
@MainActor public protocol ChiefComputerSource: AnyObject {
    /// The connected Mac to ask: `preferred` (Chief's own Mac) when it can,
    /// else the focused Mac, else any linked one; nil when none is connected
    /// or none serves the Cloud directory (`cloud-directory-v1`).
    func computerMac(preferring preferred: String?) -> ChiefComputerMac?
    /// That Mac's Cloud directory.
    func computerDirectory(on macID: String) async throws -> ChiefComputerDirectory
}

/// Chief info's Computer card (Messages' Find My slot): the account's Cloud
/// machine, live and view only, or asleep. https://github.com/manaflow-ai/cmux/issues/31488
///
/// It reads the paired Mac's Cloud directory when the page appears and again
/// each time a Mac (re)connects (``macChanged()``, from the coordinator): no
/// timer. The screen's stream is opened only while the card is on screen.
@MainActor @Observable
public final class ChiefComputer {
    public static let shared = ChiefComputer()

    /// The machine shown and its state; nil hides the card.
    public struct Shown: Equatable, Sendable {
        public var macID: String
        public var machine: ChiefComputerDirectory.Machine
        public var state: ChiefComputerState
        public var streamsDesktop: Bool
    }

    /// Held weakly: the shell sets the signed-in coordinator, and nil on sign-out.
    @ObservationIgnored public weak var source: (any ChiefComputerSource)? {
        didSet { if source !== oldValue { macChanged() } }
    }
    /// Bumped when a Mac connects, drops or gains capabilities, or the focus moves.
    public private(set) var changes = 0
    public private(set) var shown: Shown?
    /// The code the Mac refused (or ended) the current screen with.
    public private(set) var refusal: String?
    /// The live screen's stream (``Shown/state`` `.live` on a Mac that streams desktops).
    public private(set) var stream: StreamedBrowserModel?
    @ObservationIgnored private var streamKey: String?
    @ObservationIgnored private var loads = 0

    /// The page's reload key: a new value reloads.
    public struct Reload: Hashable, Sendable {
        public var changes: Int
        public var preferred: String?
    }

    public init() {}

    public func reload(preferring preferred: String?) -> Reload { Reload(changes: changes, preferred: preferred) }

    /// A Mac connected, dropped, listed new capabilities, or the focus moved.
    public func macChanged() { changes += 1 }

    /// The state the card draws: the directory's, unless the Mac refused the screen.
    public var state: ChiefComputerState? { shown.map { $0.state.refused(refusal) } }

    /// Reads the directory again (the page appeared, or a Mac changed).
    public func load(preferring preferred: String?) async {
        loads += 1
        let load = loads
        guard let source, let mac = source.computerMac(preferring: preferred) else {
            show(nil)
            return
        }
        do {
            let directory = try await source.computerDirectory(on: mac.macID)
            guard load == loads, !Task.isCancelled else { return }
            show(Self.shown(directory, mac: mac))
        } catch {
            // A cancelled read (the page closed, or a newer read) keeps what is shown.
            guard load == loads, !Task.isCancelled else { return }
            show(nil)
        }
    }

    /// The card for `directory` read from `mac`, or nil when it is hidden.
    nonisolated static func shown(_ directory: ChiefComputerDirectory, mac: ChiefComputerMac) -> Shown? {
        guard let machine = directory.computer else { return nil }
        var state = ChiefComputerState(status: machine.status)
        if state == .live, !mac.streamsDesktop { state = .unavailable }
        return Shown(macID: mac.macID, machine: machine, state: state, streamsDesktop: mac.streamsDesktop)
    }

    private func show(_ next: Shown?) {
        refusal = nil
        if next != shown { shown = next }
        guard let next, next.state == .live else {
            dropStream()
            return
        }
        let key = [next.macID, next.machine.teamID, next.machine.machineID].joined(separator: "\u{1}")
        if key == streamKey, let stream {
            // The Mac reconnected: a shown screen whose stream dropped opens again
            // (a screen off the page opens when it is shown).
            if stream.isShown { stream.reconnect() }
            return
        }
        dropStream()
        let machine = next.machine
        stream = StreamedBrowserDirectory.shared.cloudDesktopModel(
            machineID: machine.machineID, teamID: machine.teamID, macID: next.macID
        ) { [weak self] code in
            guard let self, self.streamKey == key else { return }
            self.refused(code)
        }
        streamKey = stream == nil ? nil : key
    }

    private func refused(_ code: String) {
        guard ChiefComputerState.live.refused(code) != .live, refusal != code else { return }
        refusal = code
    }

    private func dropStream() {
        stream?.close()
        stream = nil
        streamKey = nil
    }
}
