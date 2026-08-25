import Foundation

/// The one policy authority used by route selection and transport factories.
public struct CmxTransportModePolicy: Equatable, Hashable, Sendable {
    /// The selected mode this policy enforces.
    public let mode: CmxTransportMode

    /// Creates a policy for the selected transport mode.
    public init(_ mode: CmxTransportMode = .automatic) {
        self.mode = mode
    }

    /// Filters routes without changing their priority or endpoint identity.
    /// Auto returns the input unchanged; pinned modes throw when no permitted
    /// route exists. LAN uses an authenticated Iroh route constrained to a
    /// Mac-advertised LAN path, never the plaintext `.lan` TCP route itself.
    public func routes(
        from routes: [CmxAttachRoute],
        macDisplayName: String? = nil
    ) throws -> [CmxAttachRoute] {
        guard let required = mode.pinnedClass else { return routes }
        let filtered: [CmxAttachRoute]
        if mode == .lan {
            filtered = routes.filter { $0.kind == .iroh }
        } else {
            filtered = routes.filter { $0.transportClass == required }
        }
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
        if mode == .lan {
            guard route.kind == .iroh else {
                throw CmxTransportModeError.routeClassMismatch(
                    expected: required,
                    actual: route.transportClass
                )
            }
            return
        }
        guard route.transportClass == required else {
            throw CmxTransportModeError.routeClassMismatch(
                expected: required,
                actual: route.transportClass
            )
        }
    }

    /// Filters the two Iroh dial phases without allowing a private hint to
    /// escape a pinned policy. LAN keeps only broker-authorized LAN fallback
    /// hints inside the encrypted Iroh session; Tailscale never rides Iroh.
    public func irohDialPlan(_ plan: CmxIrohDialPlan) -> CmxIrohDialPlan {
        switch mode {
        case .automatic:
            return plan
        case .direct:
            return CmxIrohDialPlan(
                publicPaths: plan.publicPaths.filter {
                    $0.kind == .directAddress && $0.source == .customVPN
                },
                privateFallbackPaths: []
            )
        case .iroh:
            return CmxIrohDialPlan(
                publicPaths: plan.publicPaths.filter { $0.source == .native },
                privateFallbackPaths: plan.privateFallbackPaths.filter { $0.source == .native }
            )
        case .lan:
            return CmxIrohDialPlan(
                publicPaths: [],
                privateFallbackPaths: plan.privateFallbackPaths.filter {
                    $0.source == .lan
                }
            )
        case .tailscale:
            return CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: [])
        }
    }

    /// Filters path hints before an Iroh plan is built.
    public func irohPathHints(_ hints: [CmxIrohPathHint]) -> [CmxIrohPathHint] {
        switch mode {
        case .iroh:
            return hints.filter { $0.source == .native }
        case .lan:
            return hints.filter { $0.source == .lan }
        case .direct:
            return hints.filter { $0.source == .customVPN }
        case .automatic, .tailscale:
            return hints
        }
    }

    /// Validates an Iroh plan at the session-construction boundary.
    public func validate(irohDialPlan plan: CmxIrohDialPlan) throws {
        switch mode {
        case .automatic:
            return
        case .direct:
            guard !plan.publicPaths.isEmpty else {
                throw CmxTransportModeError.noRoute(mode: .direct, macDisplayName: nil)
            }
            guard plan.privateFallbackPaths.isEmpty,
                  plan.publicPaths.allSatisfy({
                      $0.kind == .directAddress && $0.source == .customVPN
                  }) else {
                throw CmxTransportModeError.routeClassMismatch(
                    expected: .iroh,
                    actual: .iroh
                )
            }
        case .iroh:
            let hints = plan.publicPaths + plan.privateFallbackPaths
            guard !hints.isEmpty else {
                throw CmxTransportModeError.noRoute(mode: .iroh, macDisplayName: nil)
            }
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
        case .lan:
            guard plan.publicPaths.isEmpty else {
                throw CmxTransportModeError.routeClassMismatch(
                    expected: .lan,
                    actual: .iroh
                )
            }
            guard !plan.privateFallbackPaths.isEmpty else {
                throw CmxTransportModeError.noRoute(mode: .lan, macDisplayName: nil)
            }
            guard plan.privateFallbackPaths.allSatisfy({ $0.source == .lan }) else {
                throw CmxTransportModeError.routeClassMismatch(
                    expected: .lan,
                    actual: .iroh
                )
            }
        case .tailscale:
            throw CmxTransportModeError.routeClassMismatch(
                expected: mode.pinnedClass ?? .iroh,
                actual: .iroh
            )
        }
    }

    /// Returns whether a live path is permitted by this mode.
    public func allows(path: CmxTransportPath) -> Bool {
        if mode == .direct {
            return path == .irohDirect
        }
        guard let required = mode.pinnedClass else { return true }
        return path.transportClass == required
    }
}

/// Maps route kinds into transport policy classes.
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

/// Exposes the policy class represented by an attach route.
public extension CmxAttachRoute {
    /// The policy class represented by this route.
    var transportClass: CmxTransportClass { kind.transportClass }
}

/// Exposes the policy class represented by an Iroh path hint.
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
