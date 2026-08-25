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

    /// Localized name for user-facing diagnostics and errors.
    public var displayName: String {
        switch self {
        case .lan: Self.localized("cmux.transport.class.lan", "LAN")
        case .tailscale: Self.localized("cmux.transport.class.tailscale", "Tailscale")
        case .iroh: Self.localized("cmux.transport.class.iroh", "iroh")
        case .websocket: Self.localized("cmux.transport.class.websocket", "WebSocket")
        case .debugLoopback: Self.localized("cmux.transport.class.loopback", "Loopback")
        }
    }

    private static func localized(_ key: StaticString, _ value: String) -> String {
        String(localized: key, defaultValue: String.LocalizationValue(value), bundle: .module)
    }
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
    /// Preserve the legacy per-computer direct-address allowlist. The wire
    /// transport remains Iroh; its configured candidates are enforced by the
    /// direct-candidate policy rather than this generic path filter.
    case direct

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
        case .direct: .iroh
        }
    }

    /// Whether this mode is a hard (non-fallback) constraint.
    public var isPinned: Bool { pinnedClass != nil }

    /// Stable human-readable name used in errors and fallback diagnostics.
    public var displayName: String {
        switch self {
        case .automatic: Self.localized("cmux.transport.mode.auto", "Auto")
        case .lan: Self.localized("cmux.transport.mode.lan", "LAN only")
        case .tailscale: Self.localized("cmux.transport.mode.tailscale", "Tailscale only")
        case .iroh: Self.localized("cmux.transport.mode.iroh", "iroh only")
        case .direct: Self.localized("cmux.transport.mode.direct", "Direct")
        }
    }

    private static func localized(_ key: StaticString, _ value: String) -> String {
        String(localized: key, defaultValue: String.LocalizationValue(value), bundle: .module)
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
            return Self.formatted("cmux.transport.path.lanFormat", "LAN · %@", address)
        case let .tailscale(address):
            return Self.formatted("cmux.transport.path.tailscaleFormat", "Tailscale · %@", address)
        case .irohDirect:
            return Self.localized("cmux.transport.path.irohDirect", "iroh direct")
        case let .irohRelay(region):
            if let region, !region.isEmpty {
                return Self.formatted("cmux.transport.path.irohRelayFormat", "iroh relay %@", region)
            }
            return Self.localized("cmux.transport.path.irohRelay", "iroh relay")
        case .websocket:
            return Self.localized("cmux.transport.path.websocket", "WebSocket")
        case .debugLoopback:
            return Self.localized("cmux.transport.path.loopback", "Loopback")
        }
    }

    private static func localized(_ key: StaticString, _ value: String) -> String {
        String(localized: key, defaultValue: String.LocalizationValue(value), bundle: .module)
    }

    private static func formatted(
        _ key: StaticString,
        _ value: String,
        _ argument: String
    ) -> String {
        String(
            format: localized(key, value),
            locale: .current,
            argument
        )
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
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .noRoute:
            .noRoute
        case .routeClassMismatch:
            .unsupportedRoute
        }
    }
}

/// The one policy authority used by route selection and transport factories.
public struct CmxTransportModePolicy: Equatable, Hashable, Sendable {
    public let mode: CmxTransportMode

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
            // The broker-authorized Iroh peer can discover the current LAN
            // address after a v3 identity-only pairing code, so the raw LAN
            // route need not be present in the ticket itself.
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
        if mode == .lan, route.kind == .iroh {
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
            // Iroh-only still permits Iroh's native direct/relay phases.  The
            // path-hint filter above has already removed provider-attributed
            // LAN/Tailscale hints, so retaining this plan cannot smuggle a
            // pinned network transport into an Iroh session.
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

    /// Filters path hints before an Iroh plan is built. Iroh-only keeps native
    /// Iroh hints, while LAN Only keeps only provider-authorized LAN hints;
    /// those classes remain distinct from one another at the UI boundary.
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
    ///
    /// Route filtering normally prevents a pinned Tailscale mode from reaching
    /// an Iroh factory. LAN Only is the intentional encrypted-Iroh exception;
    /// this second check protects direct callers and reconnect races.
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
            guard plan.publicPaths.isEmpty,
                  !plan.privateFallbackPaths.isEmpty,
                  plan.privateFallbackPaths.allSatisfy({ $0.source == .lan }) else {
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
