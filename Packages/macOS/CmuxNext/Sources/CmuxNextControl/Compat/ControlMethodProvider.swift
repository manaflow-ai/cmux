public import CmuxNextSettings

/// A pluggable set of control-socket methods (the registration seam).
///
/// `ControlRouter` asks registered providers first, in registration order,
/// so a provider may take over a built-in method (the cmux CLI compat layer
/// answers `system.identify` with focus and caller objects). Providers run
/// on the socket's connection task, never on the main actor; a provider that
/// needs app state reads a published snapshot or hops through its own
/// bounded queue.
public protocol ControlMethodProvider: Sendable {
    /// Methods this provider answers, reported by `system.capabilities`.
    var methods: [String] { get }
    /// True when this provider answers `method`.
    func claims(_ method: String) -> Bool
    func handle(_ request: ControlRequest) async throws -> JSONValue
    /// Answers a v1 plain-text line, or nil when the provider does not know it.
    func respondV1(_ line: String) async -> String?
}

extension ControlRouter {
    /// Adds a provider. Later registrations are asked after earlier ones.
    public func register(_ provider: any ControlMethodProvider) {
        state.withLock { $0.providers.append(provider) }
    }

    /// Socket path and access mode once the server is bound.
    public var transportInfo: (socketPath: String?, accessMode: String?) {
        state.withLock { ($0.socketPath, $0.accessMode) }
    }

    /// Built-in methods plus every provider's.
    public var allMethods: [String] {
        let providers = state.withLock { $0.providers }
        var seen = Set<String>()
        return (Self.methods + providers.flatMap(\.methods)).filter { seen.insert($0).inserted }
    }

    func claimingProvider(_ method: String) -> (any ControlMethodProvider)? {
        state.withLock { $0.providers }.first { $0.claims(method) }
    }

    func v1Fallback(_ line: String) async -> String {
        for provider in state.withLock({ $0.providers }) {
            if let response = await provider.respondV1(line) { return response }
        }
        let verb = line.split(separator: " ").first.map(String.init) ?? ""
        return "ERROR: Unknown command '\(verb)'. cmux-next speaks v2 JSON requests and a small v1 subset."
    }
}

/// The control socket's JSON type, unambiguous in files that also import
/// CmuxNextDaemon (which has its own `JSONValue`).
typealias JSON = CmuxNextSettings.JSONValue
