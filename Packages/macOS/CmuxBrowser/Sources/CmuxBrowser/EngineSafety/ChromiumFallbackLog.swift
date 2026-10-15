public import Foundation

/// Every pane that should have been Chromium but opened in WebKit, with the
/// typed reason for `debug.browser.engine`. The first fallback pane shown in
/// this process gets one notice; later fallbacks are only counted, so the
/// notice never repeats. Ported from cmux Next's `ChromiumFallbackLog`.
@MainActor
public final class ChromiumFallbackLog {
    public static let shared = ChromiumFallbackLog()

    public private(set) var lastReason: BrowserEngineUnavailableReason?
    public private(set) var lastSource: BrowserEngineChoiceSource?
    public private(set) var count = 0
    /// True once the notice was handed to a pane.
    public private(set) var notified = false
    /// Fallback panes not shown yet; the first one shown takes the notice.
    private var candidates: [UUID: BrowserEngineUnavailableReason] = [:]

    public init() {}

    /// Records a fallback for `panelID`.
    public func record(_ reason: BrowserEngineUnavailableReason, source: BrowserEngineChoiceSource, panelID: UUID?) {
        lastReason = reason
        lastSource = source
        count += 1
        guard !notified, let panelID else { return }
        candidates[panelID] = reason
    }

    /// The reason to show a notice for when `panelID` is a fallback pane and
    /// no notice was shown yet in this process (once).
    public func takeNotice(panelID: UUID) -> BrowserEngineUnavailableReason? {
        guard !notified, let reason = candidates[panelID] else { return nil }
        notified = true
        candidates = [:]
        return reason
    }

    /// Forgets a closed pane.
    public func forget(panelID: UUID) {
        candidates[panelID] = nil
    }
}
