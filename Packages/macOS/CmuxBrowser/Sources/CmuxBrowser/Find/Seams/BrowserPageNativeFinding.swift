import Foundation

/// A ``BrowserPage`` that finds text natively (``BrowserEngineCapabilities/nativeFind``).
///
/// The page owns its ``BrowserNativeFindSession`` and feeds it the engine's find results, so the
/// panel only swaps which ``BrowserFinding`` its find bar drives:
///
/// ```swift
/// let finder: any BrowserFinding = (page as? any BrowserPageNativeFinding)?.nativeFind
///     ?? BrowserFindService(evaluator: page)
/// ```
@MainActor
public protocol BrowserPageNativeFinding: BrowserPage {
    /// The page's native find session.
    var nativeFind: BrowserNativeFindSession { get }
}
