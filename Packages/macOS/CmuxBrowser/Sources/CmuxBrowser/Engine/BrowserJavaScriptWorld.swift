/// A JavaScript execution world exposed by a browser engine.
public enum BrowserJavaScriptWorld: Sendable {
    /// The page's own JavaScript world, including its global variables.
    case page

    /// An engine-isolated world that shares the page DOM but not page globals.
    case isolated
}
