import Foundation
import CmuxNextBrowser
import CmuxNextSettings

/// The engine a new browser tab gets, and why.
nonisolated struct BrowserEngineChoice: Equatable, Sendable {
    var engine: BrowserEngineTag
    /// Set when the default engine (Chromium) could not be used and the tab
    /// opens in WebKit instead. Reported once (`ChromiumFallbackLog`).
    var fallback: CEFUnavailableReason?
    /// The engine came from an existing record or page (reopen, duplicate,
    /// popup), not from the default.
    var inherited = false
    /// Someone asked for this engine (`--engine`, the other-browser modifier, a
    /// `browser.siteEngines` rule): a refused protected-media request does not
    /// move the tab to the other engine (`BrowserProtectedMedia`).
    var pinned = false

    /// What the tab loads when the user gave no URL: Chromium's New Tab
    /// page (new-tab extensions replace it), WebKit's blank page.
    var newTabURL: String {
        BrowserNewTabPage.initialURL(for: engine == .cef ? .cef : .webkit)
    }
}

/// Picks the engine for a browser tab created by any entrypoint (New
/// Browser Tab, the "+" menu, splits, terminal links, `cmux browser open`,
/// compat `surface.create --type browser`, page popups). Pure.
///
/// - An explicit engine wins. An explicit Chromium request never silently
///   becomes WebKit: it is refused with the reason.
/// - Else an inherited engine (a reopened or duplicated tab's record, a
///   popup's opener). Chromium falls back to WebKit with the reason.
/// - Else the `browser.siteEngines` rule for the tab's URL (Spotify, Netflix
///   and other protected-media sites open in WebKit by default), with the same
///   fallback.
/// - Else `browser.defaultEngine` (Chromium unless set to WebKit), with the
///   same fallback.
nonisolated enum BrowserEngineResolver {
    enum Outcome: Equatable, Sendable {
        case open(BrowserEngineChoice)
        case refuse(CEFUnavailableReason)
    }

    /// `requested` and `inherited` accept the daemon tags (`cef`, `webkit`)
    /// and `chromium`; nil, empty, or anything else means "none".
    /// `siteEngine` is the `browser.siteEngines` rule for the tab's URL, nil
    /// when none matches (or the tab has no URL yet).
    static func resolve(requested: String?, inherited: String? = nil, siteEngine: BrowserDefaultEngine? = nil,
                        defaultEngine: BrowserDefaultEngine, cefUnavailable: CEFUnavailableReason?) -> Outcome {
        switch explicitEngine(requested) {
        case .webkit?:
            return .open(BrowserEngineChoice(engine: .webkit, pinned: true))
        case .cef?:
            if let cefUnavailable { return .refuse(cefUnavailable) }
            return .open(BrowserEngineChoice(engine: .cef, pinned: true))
        case nil:
            break
        }
        let wanted: BrowserEngineTag
        let isInherited: Bool
        let pinned: Bool
        if let engine = explicitEngine(inherited) {
            (wanted, isInherited, pinned) = (engine, true, false)
        } else if let siteEngine {
            (wanted, isInherited, pinned) = (siteEngine == .chromium ? .cef : .webkit, false, true)
        } else {
            (wanted, isInherited, pinned) = (defaultEngine == .chromium ? .cef : .webkit, false, false)
        }
        guard wanted == .cef, let cefUnavailable else {
            return .open(BrowserEngineChoice(engine: wanted, inherited: isInherited, pinned: pinned))
        }
        return .open(BrowserEngineChoice(engine: .webkit, fallback: cefUnavailable, inherited: isInherited))
    }

    /// The engine a request names, nil when it names none.
    static func explicitEngine(_ requested: String?) -> BrowserEngineTag? {
        switch requested?.lowercased() {
        case "cef", "chromium", "chrome": .cef
        case "webkit", "safari": .webkit
        default: nil
        }
    }

    /// The daemon tag for a live page's engine (page popups keep their
    /// opener's engine: `window.opener` and cookies live in one engine).
    static func tag(for kind: BrowserEngineKind) -> BrowserEngineTag {
        kind == .cef ? .cef : .webkit
    }
}

extension BrowserEngineTag {
    /// The engine a URL needs: Chromium for its internal pages
    /// (ChromiumInternalURL), else nil (the default engine decides).
    nonisolated static func engine(for url: URL?) -> String? {
        guard let url, ChromiumInternalURL.needsChromium(url) else { return nil }
        return BrowserEngineTag.cef.rawValue
    }
}
