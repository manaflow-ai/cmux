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
/// - Else `browser.defaultEngine` (Chromium unless set to WebKit), with the
///   same fallback.
nonisolated enum BrowserEngineResolver {
    enum Outcome: Equatable, Sendable {
        case open(BrowserEngineChoice)
        case refuse(CEFUnavailableReason)
    }

    /// `requested` and `inherited` accept the daemon tags (`cef`, `webkit`)
    /// and `chromium`; nil, empty, or anything else means "none".
    static func resolve(requested: String?, inherited: String? = nil, defaultEngine: BrowserDefaultEngine,
                        cefUnavailable: CEFUnavailableReason?) -> Outcome {
        switch explicitEngine(requested) {
        case .webkit?:
            return .open(BrowserEngineChoice(engine: .webkit))
        case .cef?:
            if let cefUnavailable { return .refuse(cefUnavailable) }
            return .open(BrowserEngineChoice(engine: .cef))
        case nil:
            break
        }
        let wanted: BrowserEngineTag
        let isInherited: Bool
        if let engine = explicitEngine(inherited) {
            (wanted, isInherited) = (engine, true)
        } else {
            (wanted, isInherited) = (defaultEngine == .chromium ? .cef : .webkit, false)
        }
        guard wanted == .cef, let cefUnavailable else {
            return .open(BrowserEngineChoice(engine: wanted, inherited: isInherited))
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
