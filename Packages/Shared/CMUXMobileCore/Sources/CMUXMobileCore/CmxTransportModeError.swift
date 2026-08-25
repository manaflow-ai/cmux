import Foundation

/// A mode-specific route or Iroh-plan failure.
public enum CmxTransportModeError: Error, Equatable, Sendable {
    /// No route of the pinned class was advertised for the target Mac.
    case noRoute(mode: CmxTransportMode, macDisplayName: String?)
    /// A transport factory was asked to build a route outside the selected mode.
    case routeClassMismatch(expected: CmxTransportClass, actual: CmxTransportClass)
}

extension CmxTransportModeError: LocalizedError {
    /// A localized explanation suitable for logs and generic error surfaces.
    public var errorDescription: String? {
        switch self {
        case let .noRoute(mode, macDisplayName):
            let target = macDisplayName.map {
                String(
                    format: String(
                        localized: "cmux.transport.error.targetFormat",
                        defaultValue: " to %@",
                        bundle: .module
                    ),
                    locale: .current,
                    $0
                )
            } ?? ""
            return String(
                format: String(
                    localized: "cmux.transport.error.noRoute",
                    defaultValue: "%@ selected but no %@ route%@ is available. Check that the selected network is up and the Mac is advertising it.",
                    bundle: .module
                ),
                locale: .current,
                mode.displayName,
                mode.displayName,
                target
            )
        case let .routeClassMismatch(expected, actual):
            return String(
                format: String(
                    localized: "cmux.transport.error.routeClassMismatch",
                    defaultValue: "Selected %@ transport cannot use a %@ route.",
                    bundle: .module
                ),
                locale: .current,
                expected.displayName,
                actual.displayName
            )
        }
    }
}

extension CmxTransportModeError: DiagnosticFailureProviding {
    /// The diagnostic category used by reconnect and stale-route policy.
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .noRoute:
            .noRoute
        case .routeClassMismatch:
            .unsupportedRoute
        }
    }
}
