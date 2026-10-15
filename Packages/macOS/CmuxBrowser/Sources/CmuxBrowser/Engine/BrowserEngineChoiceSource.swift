import Foundation

/// Where a panel's engine choice came from.
public enum BrowserEngineChoiceSource: Equatable, Hashable, Sendable {
    /// The open request named an engine (CLI `--engine`, an API parameter).
    case explicit
    /// The engine came from an existing page or record: a popup's opener, a
    /// restored or duplicated panel.
    case inherited
    /// The `CMUX_BROWSER_ENGINE` environment variable, which test harnesses
    /// use to run every browser panel on one engine.
    case environment
    /// The `browser.engine` setting.
    case setting
}
