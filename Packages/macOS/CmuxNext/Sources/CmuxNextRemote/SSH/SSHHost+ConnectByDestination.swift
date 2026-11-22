extension Sequence where Element == SSHHost {
    /// One host per SSH destination, the one Connect to Machine… with only that destination reuses
    /// (`SSHService.existing`): the same host name (any case), user and port, the default session
    /// first, else the first listed. A palette row that passes only the destination then connects
    /// the machine it names.
    public var oneByDestination: [SSHHost] {
        var order: [String] = [], picked: [String: SSHHost] = [:]
        for host in self {
            let destination = host.destination
            let key = [destination.host.lowercased(), destination.user ?? "", destination.port.map(String.init) ?? ""].joined(separator: "\n")
            if let saved = picked[key] {
                if saved.session != RemoteSessionName.defaultName, host.session == RemoteSessionName.defaultName { picked[key] = host }
            } else {
                order.append(key)
                picked[key] = host
            }
        }
        return order.compactMap { picked[$0] }
    }
}
