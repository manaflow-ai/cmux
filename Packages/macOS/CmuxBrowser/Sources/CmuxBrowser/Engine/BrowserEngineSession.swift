public import AppKit
public import CmuxCore
public import Foundation

/// A live, engine-neutral browser surface used by pane chrome and automation.
@MainActor
public protocol BrowserEngineSession: AnyObject {
    /// The engine family implementing this session.
    var kind: BrowserEngineKind { get }

    /// The operating-system process identifier for an out-of-process browser engine.
    var contentProcessIdentifier: Int32? { get }

    /// The native view hosted by the browser pane portal.
    var contentView: NSView { get }

    /// The page zoom factor applied by the browser engine.
    var pageZoomFactor: CGFloat { get }

    /// The latest browser state snapshot.
    var state: BrowserEngineState { get }

    /// State snapshots emitted when navigation or engine lifecycle changes.
    var stateUpdates: AsyncStream<BrowserEngineState> { get }

    /// Updates whether this engine's viewport is currently visible in cmux.
    ///
    /// Engines may suspend offscreen presentation while preserving page state and navigation.
    ///
    /// - Parameter visible: Whether the pane is visible and should actively present frames.
    func setViewportVisible(_ visible: Bool)

    /// Loads a request in the current browser surface.
    ///
    /// - Parameter request: The top-level request to load.
    func load(_ request: URLRequest)

    /// Traverses backward in engine-native history.
    func goBack()

    /// Traverses forward in engine-native history.
    func goForward()

    /// Reloads the current page.
    func reload()

    /// Reloads the current page while bypassing cached content when supported.
    func reloadFromOrigin()

    /// Stops the current navigation.
    func stopLoading()

    /// Applies a page zoom factor through the browser engine.
    ///
    /// - Parameter pageZoomFactor: A positive scale where `1.0` is the default page size.
    func setPageZoomFactor(_ pageZoomFactor: CGFloat)

    /// Evaluates JavaScript in an engine-defined content world.
    ///
    /// - Parameters:
    ///   - script: The JavaScript expression or program to evaluate.
    ///   - world: The page or isolated world that should execute the script.
    /// - Returns: A Sendable value copied from the page.
    /// - Throws: An engine or JavaScript evaluation error.
    func evaluateJavaScript(
        _ script: String,
        in world: BrowserJavaScriptWorld
    ) async throws -> BrowserJavaScriptValue

    /// Installs JavaScript that runs at document start on future navigations.
    ///
    /// - Parameter script: The script source to install.
    /// - Throws: An engine error when the script cannot be installed.
    func addInitializationScript(_ script: String) async throws

    /// Reads all cookies visible to this engine session's browser context.
    ///
    /// - Returns: Engine-neutral cookie snapshots.
    /// - Throws: An engine error when the cookie store cannot be read.
    func cookies() async throws -> [BrowserEngineCookie]

    /// Creates or replaces one cookie in this engine session's browser context.
    ///
    /// - Parameter cookie: The cookie to create or replace.
    /// - Throws: An engine error when the cookie cannot be stored.
    func setCookie(_ cookie: BrowserEngineCookie) async throws

    /// Deletes one cookie from this engine session's browser context.
    ///
    /// - Parameter cookie: A cookie snapshot identifying the name, domain, and path to delete.
    /// - Throws: An engine error when the cookie cannot be deleted.
    func deleteCookie(_ cookie: BrowserEngineCookie) async throws

    /// Captures the current page viewport as PNG data.
    ///
    /// - Returns: PNG-encoded viewport pixels.
    /// - Throws: An engine or image-conversion error.
    func captureScreenshot() async throws -> Data

    /// Releases page, process, and transport resources owned by the session.
    func close()
}

public extension BrowserEngineSession {
    /// Evaluates JavaScript in the page's main world.
    ///
    /// - Parameter script: The JavaScript expression or program to evaluate.
    /// - Returns: A Sendable value copied from the page.
    /// - Throws: An engine or JavaScript evaluation error.
    func evaluateJavaScript(_ script: String) async throws -> BrowserJavaScriptValue {
        try await evaluateJavaScript(script, in: .page)
    }
}
