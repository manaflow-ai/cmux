#if canImport(IrohLib)
import CMUXMobileCore
import IrohLib

extension CmxIrohConnectionPathEvent {
    init(_ event: PathEvent) {
        switch event {
        case let .opened(_, remoteAddress, _):
            self.init(
                kind: .opened,
                pathKind: Self.pathKind(remoteAddress: remoteAddress)
            )
        case let .closed(_, remoteAddress, _, _):
            self.init(
                kind: .closed,
                pathKind: Self.pathKind(remoteAddress: remoteAddress)
            )
        case let .selected(_, remoteAddress, _):
            self.init(
                kind: .selected,
                pathKind: Self.pathKind(remoteAddress: remoteAddress)
            )
        case .lagged:
            self.init(kind: .lagged, pathKind: .unknown)
        }
    }

    private static func pathKind(remoteAddress: String) -> DiagnosticPathKind {
        if remoteAddress.contains("://") {
            return .relay
        }
        guard remoteAddress.contains(":") else {
            return .unknown
        }
        return CmxIrohIPAddressScope(socketAddress: remoteAddress).isPrivate
            ? .privateNetwork
            : .direct
    }
}
#endif
