extension Sequence {
    /// The machines whose records go to the home registry, in order: one per registry id (`session`),
    /// this Mac first, then the lowest machine id. Machines made from one image report one registry id;
    /// a record for each, put under it in turn, changed the row and the personal revision the registrar
    /// watches on every put, so each sync started the next one (about 50 writes a second at idle).
    public func onePerRegistryID(_ session: (Element) -> String?, _ isLocal: (Element) -> Bool,
                                 _ machineID: (Element) -> String) -> [Element] {
        filter { session($0) != nil }
    }
}
