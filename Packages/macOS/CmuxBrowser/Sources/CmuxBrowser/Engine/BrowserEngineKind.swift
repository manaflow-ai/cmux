public import CmuxFoundation
import Foundation

/// Browser-module compatibility name for the dependency-neutral engine value.
public typealias BrowserEngineKind = CmuxFoundation.BrowserEngineKind

public extension BrowserEngineKind {
    /// Localized Settings label for this engine.
    var displayName: String {
        switch self {
        case .webkit:
            return String(
                localized: "settings.browser.engine.webkit",
                defaultValue: "WebKit",
                bundle: .module
            )
        case .chromium:
            return String(
                localized: "settings.browser.engine.chromium",
                defaultValue: "Chromium (opt-in)",
                bundle: .module
            )
        }
    }
}
