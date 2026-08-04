public import CMUXMobileCore
import IrohLib

/// A redacted lifecycle event for one Iroh connection path.
public struct CmxIrohConnectionPathEvent: Sendable, Equatable {
    /// The operation Iroh reported for the path.
    public let kind: CmxIrohConnectionPathEventKind
    /// The privacy-safe class of the affected path.
    public let pathKind: DiagnosticPathKind

    /// Creates a redacted path event.
    ///
    /// - Parameters:
    ///   - kind: The path lifecycle operation.
    ///   - pathKind: The privacy-safe path category.
    public init(
        kind: CmxIrohConnectionPathEventKind,
        pathKind: DiagnosticPathKind
    ) {
        self.kind = kind
        self.pathKind = pathKind
    }

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
