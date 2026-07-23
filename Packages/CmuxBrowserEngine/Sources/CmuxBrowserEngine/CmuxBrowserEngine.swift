import Foundation

/// Top-level entrypoint for the cmux browser engine abstraction.
///
/// This package is the long-lived seam between cmux's `BrowserPanel` (and
/// peers) and the underlying web engine. Today it has one real backend that
/// wraps `WKWebView`. The Chromium backend is wired in but throws on use; it
/// will be implemented by the `CmuxCore.framework` work tracked in
/// `plans/chromium-engine.md`.
///
/// The Swift surface is intentionally close to `WKWebView` so that
/// callsites in `Sources/Panels/BrowserPanel.swift` and friends can migrate
/// with minimal churn. Subtle behavior differences between WebKit and
/// Chromium are translated inside the backends, not exposed at the API
/// boundary.
public enum CmuxBrowserEngine {
    /// Engine selection.
    public enum Kind: String, CaseIterable, Sendable {
        case webKit
        case chromium
    }

    /// User-facing feature flag key (read from `UserDefaults.standard`).
    ///
    /// Boolean. When `true`, new `CmuxBrowserView` instances default to the
    /// Chromium backend. Production builds default to `false` until the
    /// Chromium backend is feature-complete.
    public static let featureFlagKey = "cmux.browser.engine.chromium"

    /// The engine kind newly-constructed views should default to.
    ///
    /// Reads `featureFlagKey` from the shared defaults. Tests can override
    /// by setting `defaultKindOverride`.
    public static var defaultKind: Kind {
        if let override = defaultKindOverride { return override }
        if UserDefaults.standard.bool(forKey: featureFlagKey) {
            return .chromium
        }
        return .webKit
    }

    /// Test-only override. Set in `setUp`, clear in `tearDown`.
    /// Marked `nonisolated(unsafe)` because it is only mutated from tests
    /// that already serialize their writes; production code only reads.
    public nonisolated(unsafe) static var defaultKindOverride: Kind?

    /// Returns the underlying engine version string for diagnostics.
    public static func versionString(for kind: Kind = defaultKind) -> String {
        switch kind {
        case .webKit:
            return WebKitBrowserBackend.versionString()
        case .chromium:
            return ChromiumBrowserBackend.versionString()
        }
    }
}
