import Foundation

/// The class of network path a mobile session is allowed to use.
///
/// This is deliberately independent from the wire protocol. An Iroh session
/// can have LAN or Tailscale reachability hints, while a legacy TCP session
/// can be carried over either class. Keeping the policy vocabulary separate
/// from endpoint plumbing makes adding another path class a single mapping
/// change instead of a new boolean at every call site.
public enum CmxTransportClass: String, Codable, CaseIterable, Hashable, Sendable {
    case lan
    case tailscale
    case iroh
    case websocket
    case debugLoopback = "debug_loopback"
}

/// The user's selected transport policy.
public enum CmxTransportMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Let the runtime use its normal route ordering and Iroh fallback policy.
    case automatic = "auto"
    /// Permit only a local-network route.
    case lan
    /// Permit only a Tailscale route.
    case tailscale
    /// Permit only an Iroh route and Iroh-native paths.
    case iroh

    /// Source-compatible spelling for callers that use the UI vocabulary.
    public static var auto: Self { .automatic }
    public static var lanOnly: Self { .lan }
    public static var tailscaleOnly: Self { .tailscale }
    public static var irohOnly: Self { .iroh }

    /// The class required by a pinned mode, or `nil` for Auto.
    public var pinnedClass: CmxTransportClass? {
        switch self {
        case .automatic: nil
        case .lan: .lan
        case .tailscale: .tailscale
        case .iroh: .iroh
        }
    }

    /// Whether this mode is a hard (non-fallback) constraint.
    public var isPinned: Bool { pinnedClass != nil }

    /// Stable human-readable name used in errors and fallback diagnostics.
    public var displayName: String {
        switch self {
        case .automatic: "Auto"
        case .lan: "LAN"
        case .tailscale: "Tailscale"
        case .iroh: "iroh"
        }
    }
}

/// A concrete path currently carrying application bytes.
///
/// Coordinates are retained only in process memory for the live status line;
/// diagnostics use the corresponding redacted class and never serialize these
/// values.
public enum CmxTransportPath: Codable, Equatable, Hashable, Sendable {
    case unavailable
    case lan(address: String)
    case tailscale(address: String)
    case irohDirect
    case irohRelay(region: String?)
    case websocket
    case debugLoopback

    /// The transport class represented by this path.
    public var transportClass: CmxTransportClass? {
        switch self {
        case .unavailable: nil
        case .lan: .lan
        case .tailscale: .tailscale
        case .irohDirect, .irohRelay: .iroh
        case .websocket: .websocket
        case .debugLoopback: .debugLoopback
        }
    }

    /// A compact status-line value. The caller localizes the surrounding UI.
    public var displayValue: String {
        switch self {
        case .unavailable:
            return ""
        case let .lan(address):
            return "LAN · \(address)"
        case let .tailscale(address):
            return "Tailscale · \(address)"
        case .irohDirect:
            return "iroh direct"
        case let .irohRelay(region):
            if let region, !region.isEmpty { return "iroh relay \(region)" }
            return "iroh relay"
        case .websocket:
            return "WebSocket"
        case .debugLoopback:
            return "Loopback"
        }
    }

    /// Redacted path category suitable for the structured diagnostic ring.
    public var diagnosticPathKind: DiagnosticPathKind {
        switch self {
        case .unavailable: .unknown
        case .lan: .lan
        case .tailscale: .tailscale
        case .irohDirect: .direct
        case .irohRelay: .relay
        case .websocket: .direct
        case .debugLoopback: .loopback
        }
    }
}

/// A mode-specific route or Iroh-plan failure.
public enum CmxTransportModeError: Error, Equatable, Sendable {
    /// No route of the pinned class was advertised for the target Mac.
    case noRoute(mode: CmxTransportMode, macDisplayName: String?)
    /// A transport factory was asked to build a route outside the selected mode.
    case routeClassMismatch(expected: CmxTransportClass, actual: CmxTransportClass)
}

extension CmxTransportModeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .noRoute(mode, macDisplayName):
            let target = macDisplayName.map { " to \($0)" } ?? ""
            return "\(mode.displayName) selected but no \(mode.displayName) route\(target) is available. Check that the selected network is up and the Mac is advertising it."
        case let .routeClassMismatch(expected, actual):
            return "Selected \(expected.rawValue) transport cannot use a \(actual.rawValue) route."
        }
    }
}

extension CmxTransportModeError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind { .noRoute }
}

/// The one policy authority used by route selection and transport factories.
public struct CmxTransportModePolicy: Equatable, Hashable, Sendable {
    public let mode: CmxTransportMode

    public init(_ mode: CmxTransportMode = .automatic) {
        self.mode = mode
    }

    /// Filters routes without changing their priority or endpoint identity.
    /// Auto returns the input unchanged; pinned modes throw when no route of
    /// the requested class exists, making fallback impossible by construction.
    public func routes(
        from routes: [CmxAttachRoute],
        macDisplayName: String? = nil
    ) throws -> [CmxAttachRoute] {
        guard let required = mode.pinnedClass else { return routes }
        let filtered = routes.filter { $0.transportClass == required }
        guard !filtered.isEmpty else {
            throw CmxTransportModeError.noRoute(
                mode: mode,
                macDisplayName: macDisplayName
            )
        }
        return filtered
    }

    /// Validates one route at the transport-factory boundary.
    public func validate(route: CmxAttachRoute) throws {
        guard let required = mode.pinnedClass else { return }
        guard route.transportClass == required else {
            throw CmxTransportModeError.routeClassMismatch(
                expected: required,
                actual: route.transportClass
            )
        }
    }

    /// Filters the two Iroh dial phases without allowing a private hint to
    /// escape a pinned policy. In particular, Tailscale/LAN modes yield an
    /// empty Iroh plan rather than silently riding Iroh.
    public func irohDialPlan(_ plan: CmxIrohDialPlan) -> CmxIrohDialPlan {
        switch mode {
        case .automatic:
            return plan
        case .iroh:
            // Iroh-only still permits Iroh's native direct/relay phases.  The
            // path-hint filter above has already removed provider-attributed
            // LAN/Tailscale hints, so retaining this plan cannot smuggle a
            // pinned network transport into an Iroh session.
            return CmxIrohDialPlan(
                publicPaths: plan.publicPaths.filter { $0.source == .native },
                privateFallbackPaths: plan.privateFallbackPaths.filter { $0.source == .native }
            )
        case .lan, .tailscale:
            return CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: [])
        }
    }

    /// Filters path hints before an Iroh plan is built. Iroh-only keeps native
    /// Iroh hints but removes provider-attributed LAN/Tailscale hints, because
    /// those are distinct transport classes from the user's perspective.
    public func irohPathHints(_ hints: [CmxIrohPathHint]) -> [CmxIrohPathHint] {
        guard mode == .iroh else { return hints }
        return hints.filter { hint in
            // Provider-attributed private addresses are separate transport
            // classes.  Iroh-only retains only Iroh-native direct/relay
            // provenance so a pinned session cannot ride another network.
            hint.source == .native
        }
    }

    /// Validates an Iroh plan at the session-construction boundary.
    ///
    /// Route filtering normally prevents a pinned LAN/Tailscale mode from
    /// reaching an Iroh factory. This second check protects direct callers,
    /// reconnect races, and future factories that bypass the route catalog.
    public func validate(irohDialPlan plan: CmxIrohDialPlan) throws {
        switch mode {
        case .automatic:
            return
        case .iroh:
            let hints = plan.publicPaths + plan.privateFallbackPaths
            guard let nonNative = hints.first(where: { $0.source != .native }) else {
                return
            }
            let actual: CmxTransportClass = switch nonNative.source {
            case .lan: .lan
            case .tailscale: .tailscale
            case .native, .customVPN: .iroh
            }
            throw CmxTransportModeError.routeClassMismatch(
                expected: .iroh,
                actual: actual
            )
        case .lan, .tailscale:
            _ = plan
            throw CmxTransportModeError.routeClassMismatch(
                expected: mode.pinnedClass ?? .iroh,
                actual: .iroh
            )
        }
    }

    /// Returns whether a live path is permitted by this mode.
    public func allows(path: CmxTransportPath) -> Bool {
        guard let required = mode.pinnedClass else { return true }
        return path.transportClass == required
    }
}

public extension CmxAttachTransportKind {
    /// The policy class represented by this wire route kind.
    var transportClass: CmxTransportClass {
        switch self {
        case .lan: .lan
        case .tailscale: .tailscale
        case .iroh: .iroh
        case .websocket: .websocket
        case .debugLoopback: .debugLoopback
        }
    }
}

public extension CmxAttachRoute {
    /// The policy class represented by this route.
    var transportClass: CmxTransportClass { kind.transportClass }
}

public extension CmxIrohPathHint {
    /// The explicit transport class represented by a provider hint.
    var transportClass: CmxTransportClass {
        switch source {
        case .lan: .lan
        case .tailscale: .tailscale
        case .native, .customVPN: .iroh
        }
    }
}
