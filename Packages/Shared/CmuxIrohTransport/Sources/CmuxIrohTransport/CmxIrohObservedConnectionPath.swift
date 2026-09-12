/// Raw selected-path evidence retained only inside the transport package.
enum CmxIrohObservedConnectionPath: Equatable, Sendable {
    case unavailable
    /// A selected path snapshot that does not expose a supported address class.
    case unknown
    case direct(address: String?)
    case privateNetwork(address: String)
    case relay(url: String)

    init(snapshots: [CmxIrohConnectionPathSnapshot]) {
        guard let selected = snapshots.first(where: \.isSelected) else {
            self = .unavailable
            return
        }
        if selected.isRelay {
            self = .relay(url: selected.remoteAddress)
        } else if selected.isIP {
            self = CmxIrohIPAddressScope(socketAddress: selected.remoteAddress).isPrivate
                ? .privateNetwork(address: selected.remoteAddress)
                : .direct(address: selected.remoteAddress)
        } else {
            self = .unknown
        }
    }
}
