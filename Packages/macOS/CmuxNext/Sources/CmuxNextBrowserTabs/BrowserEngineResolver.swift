public import CmuxNextBrowser
public import CmuxNextDaemon
public import CmuxNextSettings

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
///
/// ```swift
/// let resolver = BrowserEngineResolver(defaultEngine: preference.defaultEngine, cefUnavailable: cefUnavailable())
/// let outcome = resolver.resolve(requested: "chromium")
/// ```
public nonisolated struct BrowserEngineResolver: Sendable {
    /// `browser.defaultEngine`.
    public let defaultEngine: BrowserDefaultEngine
    /// Why Chromium cannot open a tab now, nil when it can.
    public let cefUnavailable: CEFUnavailableReason?

    public init(defaultEngine: BrowserDefaultEngine, cefUnavailable: CEFUnavailableReason?) {
        self.defaultEngine = defaultEngine
        self.cefUnavailable = cefUnavailable
    }

    /// What a new tab does: open on a choice, or refuse with the reason Chromium cannot open it.
    public enum Outcome: Equatable, Sendable {
        /// The tab opens on this engine choice.
        case open(BrowserEngineChoice)
        /// An explicit Chromium request Chromium cannot serve, with the reason.
        case refuse(CEFUnavailableReason)
    }

    /// `requested` and `inherited` accept the daemon tags (`cef`, `webkit`)
    /// and `chromium`; nil, empty, or anything else means "none".
    /// `siteEngine` is the `browser.siteEngines` rule for the tab's URL, nil
    /// when none matches (or the tab has no URL yet).
    public func resolve(requested: String?, inherited: String? = nil, siteEngine: BrowserDefaultEngine? = nil) -> Outcome {
        switch CmuxNextDaemon.BrowserEngine(requested: requested) {
        case .webkit?:
            return .open(BrowserEngineChoice(engine: .webkit, pinned: true))
        case .cef?:
            if let cefUnavailable { return .refuse(cefUnavailable) }
            return .open(BrowserEngineChoice(engine: .cef, pinned: true))
        case nil:
            break
        }
        let wanted: CmuxNextDaemon.BrowserEngine
        let isInherited: Bool
        let pinned: Bool
        if let engine = CmuxNextDaemon.BrowserEngine(requested: inherited) {
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
}

extension CmuxNextDaemon.BrowserEngine {
    /// The engine a request names (`cef`, `chromium`, `chrome`, `webkit`,
    /// `safari`, any case), nil when it names none.
    public nonisolated init?(requested: String?) {
        switch requested?.lowercased() {
        case "cef", "chromium", "chrome": self = .cef
        case "webkit", "safari": self = .webkit
        default: return nil
        }
    }
}

extension BrowserEngineKind {
    /// The daemon tag for a live page's engine (page popups keep their
    /// opener's engine: `window.opener` and cookies live in one engine).
    public nonisolated var daemonEngine: CmuxNextDaemon.BrowserEngine {
        self == .cef ? .cef : .webkit
    }
}
