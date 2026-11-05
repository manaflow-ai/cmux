extension Sequence {
    /// The machines whose records go to the home registry, in order: one per registry id (`session`),
    /// this Mac first, then the lowest machine id. Machines made from one image report one registry id;
    /// a record for each, put under it in turn, changed the row and the personal revision the registrar
    /// watches on every put, so each sync started the next one (about 50 writes a second at idle).
    public func onePerRegistryID(_ session: (Element) -> String?, _ isLocal: (Element) -> Bool,
                                 _ machineID: (Element) -> String) -> [Element] {
        var chosen: [String: Element] = [:]
        for machine in self {
            guard let id = session(machine) else { continue }
            if let held = chosen[id], isLocal(held) || (!isLocal(machine) && machineID(held) <= machineID(machine)) { continue }
            chosen[id] = machine
        }
        return filter { machine in session(machine).flatMap { chosen[$0] }.map { machineID($0) == machineID(machine) } ?? false }
    }
}
