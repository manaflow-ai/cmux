import Foundation

/// Decides which engine fallbacks still need a visible notice, so a person
/// sees why Chromium was unavailable once per app run instead of on every
/// new tab.
///
/// The app owns one ledger for the process and injects it where browser
/// panels are created. A panel that opened in WebKit because of
/// ``BrowserEngineChoice/fallback`` calls ``recordFallback(_:)`` and shows
/// the notice only when it returns `true`.
///
/// ```swift
/// if let reason = choice.fallback, fallbackLedger.recordFallback(reason) {
///     panel.showEngineFallbackNotice(reason)
/// }
/// ```
@MainActor
public final class BrowserEngineFallbackNoticeLedger {
    private var noticedCodes: Set<String> = []
    private var lastReason: BrowserEngineUnavailableReason?

    /// Creates an empty ledger.
    public init() {}

    /// Records a fallback.
    /// - Parameter reason: Why the wanted engine was unavailable.
    /// - Returns: `true` the first time a reason with this
    ///   ``BrowserEngineUnavailableReason/code`` is recorded, when the caller
    ///   should show the notice; `false` afterwards.
    @discardableResult
    public func recordFallback(_ reason: BrowserEngineUnavailableReason) -> Bool {
        lastReason = reason
        return noticedCodes.insert(reason.code).inserted
    }

    /// The most recent fallback reason, for diagnostics; `nil` when none happened.
    public var mostRecentReason: BrowserEngineUnavailableReason? {
        lastReason
    }
}
