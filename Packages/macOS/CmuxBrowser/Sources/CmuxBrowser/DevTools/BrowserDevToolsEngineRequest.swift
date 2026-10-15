import Foundation

/// A request ``BrowserDevToolsPaneController`` sends to the engine.
public enum BrowserDevToolsEngineRequest: Hashable, Sendable {
    /// Opens DevTools, or focuses them when open.
    case show
    /// Opens DevTools on the Console panel.
    case console
    /// Starts the element picker.
    case inspectElement
    /// Inspects the element at a page point (view coordinates, top-left origin).
    case inspectAt(x: Int, y: Int)
    /// Closes DevTools.
    case close
}
