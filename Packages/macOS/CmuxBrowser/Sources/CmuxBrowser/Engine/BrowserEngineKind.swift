public import CmuxFoundation
import Foundation

/// Browser-module compatibility name for the dependency-neutral engine value.
public typealias BrowserEngineKind = CmuxFoundation.BrowserEngineKind

public extension BrowserEngineKind {
    /// Parses a user-facing engine token without silently falling back.
    /// Settings decoding remains fail-closed through ``init(rawValue:)``;
    /// command-line and socket callers use this parser so a typo is reported.
    ///
    /// - Parameter rawValue: User-provided engine spelling.
    /// - Returns: A recognized engine, or `nil` for an invalid option.
    static func parse(_ rawValue: String?) -> BrowserEngineKind? {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "webkit":
            return .webkit
        case "chromium", "chrome", "headless-shell":
            return .chromium
        default:
            return nil
        }
    }

    /// Whether a control/CLI `type` token resolves to a browser surface. The
    /// control-socket and command-line layers use the same normalization as
    /// the app's panel-type parser so an engine option can never be silently
    /// ignored for a terminal or simulator surface.
    ///
    /// - Parameter rawValue: User-provided panel type spelling.
    /// - Returns: `true` only when the spelling denotes a browser panel.
    static func isBrowserPanelType(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let normalized = rawValue
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return normalized == "browser"
    }

    /// Localized validation text for an unrecognized engine option.
    static var invalidOptionMessage: String {
        String(
            localized: "browser.engine.error.invalid",
            defaultValue: "--engine requires webkit or chromium",
            bundle: .module
        )
    }

    /// Localized validation text for using an engine on a non-browser surface.
    static var browserOnlyOptionMessage: String {
        String(
            localized: "browser.engine.error.browserOnly",
            defaultValue: "--engine is only supported when creating a browser pane or surface",
            bundle: .module
        )
    }

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
