import AppKit
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
    /// Chrome extension stores and prompts of the Chromium engine (set at launch).
    private(set) var chromiumExtensions: CEFBrowserExtensions?
    let fallbackNotices: BrowserEngineFallbackNoticeLedger
    private let resolver = BrowserEngineResolver()
    private let environment: [String: String]
    private let defaults: UserDefaults
    /// Starts Chromium at an idle moment once a Chromium page is likely; nil
    /// until the Chromium provider is registered.
    private(set) var chromiumWarmup: BrowserEngineWarmup?

    // Main-actor defaults are built in the body: default argument expressions are
    // evaluated in a nonisolated context and cannot call main-actor initializers.
    init(
        registry: BrowserEngineRegistry? = nil,
        fallbackNotices: BrowserEngineFallbackNoticeLedger? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        self.registry = registry ?? BrowserEngineRegistry()
        self.fallbackNotices = fallbackNotices ?? BrowserEngineFallbackNoticeLedger()
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
        let extensions = CEFBrowserExtensions(
            runtime: .shared,
            window: { browserID in
                // The asking tab's window, else a visible cmux window; none aborts the prompt.
                CEFRuntime.shared.browser(id: browserID)?.hostView.window.flatMap { $0.isVisible ? $0 : nil }
                    ?? NSApp.windows.first { $0.isVisible && $0.isMainWindow }
                    ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.parent == nil && !($0 is NSPanel) }
            },
            present: { content, icon, window in
                // Chromium raised it, so a Chromium page shows in that window.
                await BrowserExtensionDialogPresenter().present(content, icon: icon, in: window, overChromiumPage: true)
            },
            installed: { notice, _ in
                // The store page shows its own confirmation; VoiceOver hears it here (spec §0.7a).
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: BrowserExtensionAccessibilityText.added(notice.name),
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ]
                )
            }
        )
        chromiumExtensions = extensions
        let chromium = CEFBrowserEngineProvider(
            runtime: .shared,
            devToolsLayoutStore: BrowserDevToolsLayoutStore(defaults: defaults),
            extensions: extensions.stores
        )
        registry.register(chromium)
        // Nothing loads here: the warmup only acts once a Chromium page is likely.
        chromiumWarmup = BrowserEngineWarmup(engine: chromium)
        // New browser panels open in Chromium: a Chromium page is likely soon.
        if environmentOverride == .chromium || BrowserEngineKind.configured(defaults: defaults) == .chromium {
            chromiumLikely(.defaultEngine)
        }
    }

    /// A Chromium page is likely soon: start Chromium at the next idle moment.
    /// Only the first call per process acts; it does nothing while Chromium
    /// is unavailable or already running.
    /// - Parameter reason: Why a Chromium page is likely.
    func chromiumLikely(_ reason: BrowserEngineWarmupReason) {
        chromiumWarmup?.engineLikely(reason)
    }

    /// Whether an engine can create pages now.
    func availability(for kind: BrowserEngineKind) -> BrowserEngineAvailability {
        registry.availability(for: kind)
    }
}
