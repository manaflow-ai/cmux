import Foundation

/// The engine side of in-pane developer tools (Chromium through the CEF shim).
///
/// ``BrowserDevToolsPaneController`` decides where the tools go and when; the engine only runs
/// requests, takes the placement it is asked for, and reports lifetime events back to the
/// controller (``BrowserDevToolsPaneController/engineWillOpenDevTools()``,
/// ``BrowserDevToolsPaneController/engineDidOpenDevTools(docked:)``,
/// ``BrowserDevToolsPaneController/engineDidCloseDevTools()``).
@MainActor
public protocol BrowserDevToolsEngineDriving: AnyObject {
    /// Whether the engine can show DevTools as a child of a cmux view, so docking and moving
    /// between dock and window keep the same DevTools alive.
    var supportsEmbeddedDevTools: Bool { get }

    /// Runs a DevTools request on the page.
    /// - Parameter request: The request.
    func runDevToolsRequest(_ request: BrowserDevToolsEngineRequest)

    /// Tells the engine where the next DevTools it creates goes. Called synchronously while the
    /// engine reports that it is about to create DevTools.
    /// - Parameter placement: The placement.
    func setDevToolsPlacement(_ placement: BrowserDevToolsPlacement)

    /// Gives keyboard focus to the open DevTools, or takes it away.
    /// - Parameter focused: `true` to focus the tools.
    func setDevToolsFocused(_ focused: Bool)
}
