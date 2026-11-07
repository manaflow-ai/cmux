/// The Cloud machines a chat start is bringing up now, from its connect until its agent runs (prod, 2026-11-05: the
/// app's update of a just-resumed machine restarted its daemon mid-start, and the start failed "started but its
/// agent didn't (cmux-tui connection closed: EOF)"). The app's automatic machine update answers busy for such a
/// machine, so it runs after its backoff, once the agent runs; a start's own update (its daemon refused the start)
/// is not held. An update that already ran when the start came is waited out by the start.
@MainActor
public final class CloudStartGate {
    private var starts: [String: Int] = [:]

    public init() {}

    public func enter(_ machineID: String) { starts[machineID, default: 0] += 1 }

    public func leave(_ machineID: String) {
        let left = starts[machineID, default: 1] - 1
        starts[machineID] = left > 0 ? left : nil
    }

    /// Whether a start is bringing machine `machineID` up now.
    public func contains(_ machineID: String) -> Bool { starts[machineID] != nil }
}
