import CMUXMobileCore

/// Raw selected-path evidence retained only inside the transport package.
enum CmxIrohObservedConnectionPath: Equatable, Sendable {
    case unavailable
    case direct
    case privateNetwork
    case relay(url: String)

    /// The privacy-safe path class used by the shared diagnostic vocabulary.
    var diagnosticPathKind: DiagnosticPathKind {
        switch self {
        case .unavailable:
            .unknown
        case .direct:
            .direct
        case .privateNetwork:
            .privateNetwork
        case .relay:
            .relay
        }
    }

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
