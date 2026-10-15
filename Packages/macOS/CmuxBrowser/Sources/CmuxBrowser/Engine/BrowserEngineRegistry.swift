import Foundation

/// The engines this app process can use, keyed by kind.
///
/// The app creates one registry at startup and injects it wherever browser
/// panels are created. An engine without a registered provider reports
/// ``BrowserEngineUnavailableReason/notBundled``. WebKit needs no provider to
/// be available: browser panels create WebKit pages themselves today.
///
/// ```swift
/// let registry = BrowserEngineRegistry()
/// if let chromium = makeChromiumProviderIfBundled() { registry.register(chromium) }
/// registry.availability(for: .chromium)  // .available or .unavailable(.notBundled)
/// ```
@MainActor
public final class BrowserEngineRegistry {
    private var providers: [BrowserEngineKind: any BrowserEngineProviding] = [:]

    /// Creates a registry.
    /// - Parameter providers: Providers to register; a later provider for the
    ///   same kind replaces an earlier one.
    public init(providers: [any BrowserEngineProviding] = []) {
        for provider in providers {
            register(provider)
        }
    }

    /// Registers a provider, replacing any provider of the same kind.
    /// - Parameter provider: The provider.
    public func register(_ provider: any BrowserEngineProviding) {
        providers[provider.kind] = provider
    }

    /// The provider for an engine.
    /// - Parameter kind: The engine.
    /// - Returns: The registered provider, or `nil`.
    public func provider(for kind: BrowserEngineKind) -> (any BrowserEngineProviding)? {
        providers[kind]
    }

    /// Whether an engine can create pages now.
    /// - Parameter kind: The engine.
    /// - Returns: The provider's availability; WebKit is always available,
    ///   any other engine without a provider is ``BrowserEngineUnavailableReason/notBundled``.
    public func availability(for kind: BrowserEngineKind) -> BrowserEngineAvailability {
        if let provider = providers[kind] {
            return provider.availability
        }
        return kind == .webkit ? .available : .unavailable(.notBundled)
    }

    /// Creates a page with the registered provider.
    /// - Parameters:
    ///   - kind: The engine.
    ///   - configuration: The page configuration.
    /// - Returns: A new page.
    /// - Throws: ``BrowserEngineError/unavailable(_:_:)`` when no provider is
    ///   registered or the engine is unavailable;
    ///   ``BrowserEngineError/unsupported(_:)`` for WebKit without a provider,
    ///   because browser panels create WebKit pages themselves.
    public func makePage(_ kind: BrowserEngineKind, _ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
        guard let provider = providers[kind] else {
            if kind == .webkit {
                throw BrowserEngineError.unsupported("webkitPagesAreCreatedByThePanel")
            }
            throw BrowserEngineError.unavailable(kind, .notBundled)
        }
        if let reason = provider.availability.unavailableReason {
            throw BrowserEngineError.unavailable(kind, reason)
        }
        return try provider.makePage(configuration)
    }
}
