import Foundation

/// A mode-specific route or Iroh-plan failure.
public enum CmxTransportModeError: Error, Equatable, Sendable {
    /// No route of the pinned class was advertised for the target Mac.
    case noRoute(mode: CmxTransportMode, macDisplayName: String?)
    /// A transport factory was asked to build a route outside the selected mode.
    case routeClassMismatch(expected: CmxTransportClass, actual: CmxTransportClass)
    /// A Direct-only address allowlist was attached to a non-Direct request.
    case directCandidatesRequireDirectMode(selectedMode: CmxTransportMode)
    /// A live path violated the exact selected mode.
    case pathNotAllowed(mode: CmxTransportMode, actual: CmxTransportClass)
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
                mode.pinnedClass?.displayName ?? mode.displayName,
                target
            )
        case let .routeClassMismatch(expected, actual):
            if expected == actual {
                return String(
                    format: String(
                        localized: "cmux.transport.error.routeClassMismatchSameClass",
                        defaultValue: "The selected transport mode cannot use a %@ route.",
                        bundle: .module
                    ),
                    locale: .current,
                    actual.displayName
                )
            }
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
        case let .directCandidatesRequireDirectMode(selectedMode):
            return String(
                format: String(
                    localized: "cmux.transport.error.directCandidatesRequireDirect",
                    defaultValue: "Direct address candidates require Direct mode; %@ was selected.",
                    bundle: .module
                ),
                locale: .current,
                selectedMode.displayName
            )
        case let .pathNotAllowed(mode, actual):
            return String(
                format: String(
                    localized: "cmux.transport.error.pathNotAllowed",
                    defaultValue: "The selected %@ mode cannot use a %@ route.",
                    bundle: .module
                ),
                locale: .current,
                mode.displayName,
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
        case .routeClassMismatch, .directCandidatesRequireDirectMode, .pathNotAllowed:
            .unsupportedRoute
        }
    }
}
