import Foundation

/// Which browser engine a new browser pane should be created with.
///
/// cmux ships with two browser engines that can be selected via the
/// **Debug → Browser Engine** menu:
///
/// - ``wkwebview`` — the default. Uses WebKit, the same engine Safari
///   ships. Production-tested, no separate process tree on macOS, but
///   no Chromium-extension support.
/// - ``cef`` — Chromium Embedded Framework Chrome runtime. Adds support
///   for Chrome extensions (MV3, popups, `chrome.storage`, etc.) at the
///   cost of an extra ~270 MiB framework + 5 helper processes per
///   cmux launch. **Experimental.** Requires the `CEF/` SwiftPM
///   package to be wired into the Xcode project; see
///   `CEF/INTEGRATION.md`.
///
/// The selection is stored in `UserDefaults` under
/// ``BrowserEngineKind/userDefaultsKey`` and applies to *newly created*
/// browser panes only. Existing panes keep the engine they were born
/// with. Switching the flag mid-session does not migrate panes.
public enum BrowserEngineKind: String, CaseIterable, Sendable {
    case wkwebview
    case cef

    /// `UserDefaults` key — also the `@AppStorage` key — used by the
    /// Debug menu toggle and by every code path that creates a new
    /// browser pane.
    public static let userDefaultsKey = "browser.engine.kind"

    /// Default for fresh installs and for unrecognised stored values.
    /// Always WKWebView; the CEF engine is opt-in.
    public static let `default`: BrowserEngineKind = .wkwebview

    /// The currently-active selection, resolved from `UserDefaults`.
    /// SwiftUI surfaces should prefer `@AppStorage(userDefaultsKey)`
    /// to participate in live updates; non-SwiftUI call sites can use
    /// this convenience accessor.
    public static var current: BrowserEngineKind {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
        guard let raw, let kind = BrowserEngineKind(rawValue: raw) else {
            return .default
        }
        if kind == .cef {
            guard isCEFAvailable,
                  isCEFSupportedOnCurrentOS,
                  CEFRuntimeLocator.resolvedLocation() != nil else {
                return .default
            }
        }
        return kind
    }

    /// Whether the CEF engine is *available* in this build of cmux.
    /// True only when the `CMUXCEF` SwiftPM package is linked. cmux
    /// builds without the package compile fine but flip this to false
    /// so the Debug menu can grey out the option.
    public static var isCEFAvailable: Bool {
        #if canImport(CMUXCEF)
        return true
        #else
        return false
        #endif
    }

    /// Whether the current macOS version can run this CEF integration.
    /// Keep this aligned with `CEFEngine.start`, which rejects older
    /// macOS versions before booting Chromium.
    public static var isCEFSupportedOnCurrentOS: Bool {
        if #available(macOS 15.0, *) {
            return true
        } else {
            return false
        }
    }

    /// True only when CEF is linked and the current OS can run it.
    static var canSelectCEF: Bool {
        isCEFAvailable && isCEFSupportedOnCurrentOS
    }

    /// Human-readable label used by the Debug menu.
    public var displayLabel: String {
        switch self {
        case .wkwebview:
            return String(localized: "browserEngine.wkwebview.label", defaultValue: "WKWebView (default)")
        case .cef:
            return String(localized: "browserEngine.cef.label", defaultValue: "CEF - Chromium (experimental)")
        }
    }
}
