public import Foundation

/// Holds one engine per kind and creates tabs through them.
public final class BrowserEngineRegistry {
    private var engines: [BrowserEngineKind: any BrowserEngine] = [:]

    public init(engines: [any BrowserEngine] = []) {
        for engine in engines { register(engine) }
    }

    public func register(_ engine: any BrowserEngine) {
        engines[engine.kind] = engine
    }

    public func engine(for kind: BrowserEngineKind) -> (any BrowserEngine)? {
        engines[kind]
    }

    /// Kinds that can create tabs now, in declaration order.
    public var availableKinds: [BrowserEngineKind] {
        BrowserEngineKind.allCases.filter { engines[$0]?.availability.isAvailable == true }
    }

    public func makeTab(kind: BrowserEngineKind, _ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        guard let engine = engines[kind] else {
            throw BrowserEngineError.engineNotRegistered(kind)
        }
        // A proxied tab opens only in Chromium (fail closed, never unproxied).
        if configuration.machineStore != nil, kind != .cef { throw BrowserEngineError.machineStoreRequiresChromium }
        if case .unavailable(let reason) = engine.availability {
            throw BrowserEngineError.engineUnavailable(kind, reason: reason)
        }
        return try await engine.makeTab(configuration)
    }
}
