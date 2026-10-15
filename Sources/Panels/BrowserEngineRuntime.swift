import CmuxBrowser
import CmuxCEF
import CmuxCEFBrowser
import Foundation

/// The app's browser engines: which engines this process can use, and which
/// one a new browser panel opens with.
///
/// The app registers engine providers here at launch (the Chromium provider
/// only when the runtime is bundled). Browser panels resolve their engine
/// through ``resolve(requested:inherited:)``: an explicit per-open request,
/// then `CMUX_BROWSER_ENGINE`, then an inherited engine, then
/// `browser.engine`. WebKit needs no provider.
@MainActor
final class BrowserEngineRuntime {
    /// The process-wide runtime. Browser panels are created from many entry
    /// points that have no shared composition object to inject it through.
    static let shared = BrowserEngineRuntime()

    let registry: BrowserEngineRegistry
    let fallbackNotices: BrowserEngineFallbackNoticeLedger
    private let resolver = BrowserEngineResolver()
    private let environment: [String: String]
    private let defaults: UserDefaults

    init(
        registry: BrowserEngineRegistry = BrowserEngineRegistry(),
        fallbackNotices: BrowserEngineFallbackNoticeLedger = BrowserEngineFallbackNoticeLedger(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        self.registry = registry
        self.fallbackNotices = fallbackNotices
        self.environment = environment
        self.defaults = defaults
    }

    /// The engine `CMUX_BROWSER_ENGINE` forces, if any.
    var environmentOverride: BrowserEngineKind? {
        BrowserEngineKind.environmentOverride(environment)
    }

    /// Picks the engine for a new browser panel.
    /// - Parameters:
    ///   - requested: The engine the open request named (CLI `--engine`), or `nil`.
    ///   - inherited: The engine of an opener or restored panel, or `nil`.
    /// - Returns: The engine to open with, or a refusal for an unavailable
    ///   explicit request.
    func resolve(requested: BrowserEngineKind?, inherited: BrowserEngineKind? = nil) -> BrowserEngineResolution {
        resolver.resolve(
            requested: requested,
            environment: environmentOverride,
            inherited: inherited,
            setting: BrowserEngineKind.configured(defaults: defaults),
            availability: { [registry] kind in registry.availability(for: kind) }
        )
    }

    /// Registers the engines this build carries. The Chromium provider is
    /// always registered; it reports `notBundled` when the app has no
    /// Chromium runtime. Called once at launch.
    func registerBundledEngines() {
        guard registry.provider(for: .chromium) == nil else { return }
        registry.register(CEFBrowserEngineProvider(
            runtime: .shared,
            devToolsLayoutStore: BrowserDevToolsLayoutStore(defaults: defaults)
        ))
    }

    /// Whether an engine can create pages now.
    func availability(for kind: BrowserEngineKind) -> BrowserEngineAvailability {
        registry.availability(for: kind)
    }
}
