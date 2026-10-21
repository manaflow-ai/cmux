/// What one Update Everything run would change, machine by machine, read once when the person
/// asks; the confirmation shows it and the runner follows it.
public nonisolated struct UpdateEverythingPlan: Sendable, Codable, Equatable {
    /// This Mac first, then the connected machines in sidebar order.
    public var machines: [UpdateEverythingMachine]

    /// - Parameter machines: This Mac first, then the connected machines.
    public init(machines: [UpdateEverythingMachine]) {
        self.machines = machines
    }

    /// Nothing anywhere to update: the action says so instead of asking.
    public var isUpToDate: Bool { machines.allSatisfy(\.isUpToDate) }

    /// Running threads the updates restart, across every machine.
    public var interruptedThreads: Int { machines.reduce(0) { $0 + $1.interruptedThreads } }

    /// Whether the app itself updates, so the run ends in a relaunch.
    public var relaunches: Bool { machines.contains { $0.app != nil } }
}
