public import Foundation

/// Where a link activated inside a terminal should open.
public enum TerminalOpenURLTarget: Equatable, Sendable {
    /// Open inside cmux's embedded browser panel.
    case embeddedBrowser(URL)
    /// Hand off to the system (default browser, Finder, or scheme handler).
    case external(URL)

    /// The destination URL regardless of routing.
    public var url: URL {
        switch self {
        case let .embeddedBrowser(url), let .external(url):
            return url
        }
    }
}
