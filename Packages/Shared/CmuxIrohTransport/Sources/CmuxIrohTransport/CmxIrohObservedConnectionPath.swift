/// Raw selected-path evidence retained only inside the transport package.
enum CmxIrohObservedConnectionPath: Equatable, Sendable {
    case unavailable
    case direct
    case privateNetwork
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
                ? .privateNetwork
                : .direct
        } else {
            self = .unavailable
        }
    }
}
