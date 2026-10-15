public import AppKit
public import CmuxBrowser
public import CmuxCEF
public import CmuxCEFExtensions
import Foundation

/// Chrome extension support for the Chromium engine: the per-profile stores
/// pages join, and the install/permission prompt handler.
///
/// The app creates one at launch, passes ``stores`` to
/// ``CEFBrowserEngineProvider``, and keeps it alive.
///
/// ```swift
/// let extensions = CEFBrowserExtensions(runtime: .shared, window: { ... }, present: { ... })
/// registry.register(CEFBrowserEngineProvider(runtime: .shared, extensions: extensions.stores))
/// ```
@MainActor
public final class CEFBrowserExtensions {
    /// The per-profile extension stores.
    public let stores: CEFExtensionStores
    /// The prompt handler.
    public let prompts: CEFExtensionPrompts

    /// Creates the stores and the prompt handler and starts observing `runtime`.
    ///
    /// - Parameters:
    ///   - runtime: The process's Chromium runtime.
    ///   - window: The window to ask in for a prompting browser id (the tab's
    ///     window, else a visible cmux window); nil aborts the prompt.
    ///   - present: Shows a prompt sheet and returns whether the person accepted.
    ///   - installed: Called when an extension finished installing.
    public init(
        runtime: CEFRuntime,
        window: @escaping @MainActor (Int32) -> NSWindow?,
        present: @escaping CEFExtensionPrompts.Present,
        installed: @escaping @MainActor (BrowserExtensionInstalledNotice, Int32) -> Void = { _, _ in }
    ) {
        let calls = CEFShimExtensionCalls(runtime: runtime)
        stores = CEFExtensionStores(calls: calls)
        let stores = stores
        prompts = CEFExtensionPrompts(
            calls: calls,
            window: window,
            present: present,
            installed: { notice, browser in
                stores.handle(.extensionsChanged, browser: browser, window: 0)
                installed(notice, browser)
            }
        )
        stores.observe(runtime)
        prompts.observe(runtime)
    }
}
