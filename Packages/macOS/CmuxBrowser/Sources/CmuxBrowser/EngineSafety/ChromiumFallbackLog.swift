public import Foundation

/// Why a pane that asked for Chromium opened in WebKit instead.
public enum ChromiumUnavailableReason: String, Equatable, Sendable {
    /// This build has no Chromium engine (the optional CEF artifact was not
    /// fetched, for example a contributor build without the artifact store).
    case notBundled
    /// The engine is bundled but failed to load or initialize.
    case startFailed
    /// The engine already shut down (the app is quitting).
    case shutDown
}

/// Every pane that should have been Chromium but opened in WebKit, with the
/// typed reason for `debug.browser.engine`. The first fallback pane shown in
/// this process gets one notice; later fallbacks are only counted, so the
/// notice never repeats. Ported from cmux Next's `ChromiumFallbackLog`.
@MainActor
public final class ChromiumFallbackLog {
    public enum Source: String, Sendable {
        /// A new pane whose engine came from the `browser.engine` setting.
        case setting
        /// A pane whose open request named Chromium (CLI `--engine`,
        /// session restore).
        case explicitRequest
    }

    public static let shared = ChromiumFallbackLog()

    public private(set) var lastReason: ChromiumUnavailableReason?
    public private(set) var lastSource: Source?
    public private(set) var count = 0
    /// True once the notice was handed to a pane.
    public private(set) var notified = false
    /// Fallback panes not shown yet; the first one shown takes the notice.
    private var candidates: [UUID: ChromiumUnavailableReason] = [:]

    public init() {}

    /// Records a fallback for `panelID`.
    public func record(_ reason: ChromiumUnavailableReason, source: Source, panelID: UUID?) {
        lastReason = reason
        lastSource = source
        count += 1
        guard !notified, let panelID else { return }
        candidates[panelID] = reason
    }

    /// The reason to show a notice for when `panelID` is a fallback pane and
    /// no notice was shown yet in this process (once).
    public func takeNotice(panelID: UUID) -> ChromiumUnavailableReason? {
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
