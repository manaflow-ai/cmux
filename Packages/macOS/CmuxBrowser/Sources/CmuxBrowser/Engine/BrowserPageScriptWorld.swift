import Foundation

/// The JavaScript world a script runs in.
public enum BrowserPageScriptWorld: Equatable, Hashable, Sendable {
    /// The page's own world: the script sees and changes page globals.
    case page
    /// An isolated world with the given name: the script shares the DOM but
    /// not the page's globals.
    case isolated(String)
}
