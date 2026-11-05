public import CmuxNextCloud

/// What the Chief Settings card's Computer section shows (cmux issue 31488, like Messages' Find
/// My slot on a contact): the account's Cloud machine and its state. The section shows only when
/// the plan pays for cmux Cloud and some machine has run at least once. The machine is the first
/// running one, else the first that has run; machines that are gone or going never count.
public struct HomeChiefComputer: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Running: its screen streams.
        case live
        /// Paused or pausing.
        case asleep
        /// Starting or provisioning.
        case waking
        /// Failed or unknown.
        case unavailable
    }

    public var machineID: String
    public var name: String
    public var state: State

    public init(machineID: String, name: String, state: State) {
        self.machineID = machineID
        self.name = name
        self.state = state
    }

    /// The section for `machines` (the account's Cloud machines, in the app's order); nil hides it.
    public init?(machines: [CloudMachine], paid: Bool) {
        let kept = machines.filter { !$0.isGoneForPhones }
        guard paid, let machine = kept.first(where: { $0.shownStatus == .running }) ?? kept.first(where: \.hasRun),
              kept.contains(where: \.hasRun) else { return nil }
        self.init(machineID: machine.id, name: machine.shownName ?? machine.id, state: Self.state(of: machine.shownStatus))
    }

    static func state(of status: CloudMachine.Status) -> State {
        switch status {
        case .running: .live
        case .paused, .pausing: .asleep
        case .starting, .provisioning: .waking
        case .failed, .destroyed, .deleting, .unknown: .unavailable
        }
    }
}
