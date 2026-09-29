import Foundation

/// Placeholder for the Chromium (CEF fork) engine.
///
/// The real engine wraps the `cmux-cef` Rust static library, initializes CEF
/// lazily on the first tab with an external message pump, and presents tabs
/// as `.childWindow` (plans/cmux-next/browser.md section 3). Until that lands
/// it reports unavailable, so callers already handle the "no CEF" case the
/// same way `CMUX_CEF=0` builds will.
public final class CEFEngine: BrowserEngine {
    public let kind: BrowserEngineKind = .cef

    /// What the real engine will offer. Callers can show these in UI (for
    /// example, "Reopen in Chromium for extensions") without a live engine.
    public let capabilities: BrowserCapabilities = [
        .cdp, .extensions, .trustedInput, .networkIntercept, .crossOriginFrames,
        .devTools, .downloads, .snapshots, .findMatchCount,
    ]

    public init() {}

    public var availability: BrowserEngineAvailability {
        .unavailable(reason: Strings.cefUnavailable)
    }

    public func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        throw BrowserEngineError.engineUnavailable(kind, reason: Strings.cefUnavailable)
    }
}
