public import CmuxBrowser
public import CmuxCEF
import Foundation

/// The Chromium engine for browser panels.
///
/// The app registers one provider in its `BrowserEngineRegistry` at launch.
/// Availability follows the CEF runtime: not bundled in builds without the
/// Chromium artifact, failed after a start error, shut down while quitting.
/// A page is created right away; Chromium starts when its first page's view
/// enters a window.
///
/// ```swift
/// registry.register(CEFBrowserEngineProvider(
///     runtime: .shared, devToolsLayoutStore: BrowserDevToolsLayoutStore(defaults: .standard)
/// ))
/// ```
@MainActor
public final class CEFBrowserEngineProvider: BrowserEngineProviding {
    private let runtime: CEFRuntime
    private let devToolsLayoutStore: BrowserDevToolsLayoutStore
    /// Shared by this provider's pages for Memory Saver's process accounting.
    private let rendererProcesses: CEFRendererProcessResolver

    /// Creates the provider.
    /// - Parameters:
    ///   - runtime: The process's CEF runtime.
    ///   - devToolsLayoutStore: Remembers the DevTools dock side and sizes across pages.
    public init(runtime: CEFRuntime, devToolsLayoutStore: BrowserDevToolsLayoutStore) {
        self.runtime = runtime
        self.devToolsLayoutStore = devToolsLayoutStore
        rendererProcesses = CEFRendererProcessResolver()
    }

    /// Always ``BrowserEngineKind/chromium``.
    public var kind: BrowserEngineKind { .chromium }

    /// The runtime's availability.
    public var availability: BrowserEngineAvailability {
        if let reason = runtime.unavailableReason {
            return .unavailable(reason.browserEngineReason)
        }
        return .available
    }

    /// Chromium's features.
    public var capabilities: BrowserEngineCapabilities {
        CEFBrowserPage.engineCapabilities
    }

    /// Creates a Chromium page for a panel.
    /// - Parameter configuration: The panel's profile, initial URL, zoom and restore state.
    /// - Returns: The page; Chromium creates its browser when the page's view
    ///   enters a window.
    /// - Throws: ``BrowserEngineError/unavailable(_:_:)`` when the runtime cannot run.
    public func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
        if let reason = runtime.unavailableReason {
            throw BrowserEngineError.unavailable(.chromium, reason.browserEngineReason)
        }
        let restore: String?
        if case .chromium(let state) = configuration.restoreState {
            restore = state
        } else {
            restore = nil
        }
        let browser = CEFBrowser(
            configuration: CEFBrowserConfiguration(
                profile: configuration.profileID,
                initialURL: configuration.initialURL,
                zoom: configuration.zoom,
                restoreState: restore
            )
        )
        let page = CEFBrowserPage(
            browser: browser,
            shim: { [runtime] in runtime.shim },
            devToolsLayoutStore: devToolsLayoutStore
        )
        page.rendererProcesses = rendererProcesses
        return page
    }
}
