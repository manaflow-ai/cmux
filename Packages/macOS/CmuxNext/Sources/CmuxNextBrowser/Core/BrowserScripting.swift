import Foundation

/// JavaScript world for `evaluate`.
public nonisolated enum BrowserScriptWorld: Hashable, Sendable {
    /// The page's own world: sees page globals.
    case page
    /// An isolated world: shares the DOM but not page globals. Use for
    /// automation so pages cannot tamper with the scripts.
    case isolated
}

public nonisolated enum BrowserTabError: Error, Hashable, Sendable {
    case closed
    case snapshotUnavailable
    case javaScript(String)
    case unsupported(String)
    /// The engine did not answer in time (what, deadline).
    case timedOut(String)
}
