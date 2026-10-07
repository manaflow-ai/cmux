/// The fault hook and the owner to stop for the current endpoints of a rig.
actor RigState<Faults: Sendable, Owner: Sendable> {
    private(set) var faults: Faults?
    private(set) var owner: Owner?

    func set(_ faults: Faults?, _ owner: Owner?) {
        self.faults = faults
        self.owner = owner
    }
}
