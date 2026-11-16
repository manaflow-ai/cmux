public import Foundation
public import Observation
internal import ObjectiveC

/// The language cmux's own native text is in, switched live (`app.language`, Leo 2026-11-16: "we
/// gotta add settings for changing lanugages"). Which code to use is cmux-config's and the
/// settings snapshot's; this only makes cmux's own string bundles answer in it.
///
/// Every native string is a `String(localized:bundle: .module)` read of a SwiftPM resource bundle
/// (`Contents/Resources/*.bundle`). Each such bundle is adopted (``adopt(_:)``, by the launch
/// warm-up that opens them all): its class becomes ``AppLanguageBundle``, which answers
/// `localizedString(forKey:value:table:)` from the chosen language's `.lproj`, and with no chosen
/// language (System) exactly as before. Only cmux's own resource bundles are adopted: never
/// `Bundle.main`, a framework or the system's.
///
/// Live: every lookup reads ``code`` through Observation, so a SwiftUI body, an `ObservationStream`
/// or a `withObservationTracking` scope that looked up a cmux string runs again when the language
/// changes, with its state kept. Text computed outside a tracking scope needs ``code`` read in its
/// observation (the sidebar's sections). The menu bar and the action catalog (command titles) are
/// made once per launch: those take the language at the next launch.
public final class AppLanguage: Observable, @unchecked Sendable { // crash-allow: its only stored values are a Mutex and the Sendable ObservationRegistrar
    public static let shared = AppLanguage()

    private struct State {
        var code: String?
        /// Each adopted bundle's `.lproj` for ``code``, by bundle path (nil: the bundle has none).
        var localized: [String: Bundle?] = [:]
    }

    private let state = Mutex(State())
    private let registrar = ObservationRegistrar()

    init() {}

    /// The chosen language (a shipped code such as "ja" or "pt-BR"), nil for System. Observed.
    public var code: String? {
        registrar.access(self, keyPath: \.code)
        return state.withLock { $0.code }
    }

    /// The languages cmux's own text resolves against: the chosen one, else the system's. Observed.
    public var preferredLanguages: [String] {
        code.map { [$0] } ?? Locale.preferredLanguages
    }

    /// Switches cmux's native text to `code` (nil: System). Views that read a cmux string in an
    /// observation scope run again; the same code again does nothing.
    public func set(_ code: String?) {
        guard state.withLock({ $0.code }) != code else { return }
        registrar.withMutation(of: self, keyPath: \.code) {
            state.withLock { $0 = State(code: code) }
        }
    }

    /// Makes `bundle` (one of cmux's own resource bundles) answer in the chosen language. Only a
    /// plain `Bundle` changes class: a bundle already adopted, or of another class, stays as it is.
    /// ``AppLanguageBundle`` adds no stored state, so the instance keeps its layout.
    public func adopt(_ bundle: Bundle) {
        guard object_getClass(bundle) == Bundle.self else { return }
        object_setClass(bundle, AppLanguageBundle.self)
    }

    /// The `.lproj` bundle of `bundle` for the chosen language, nil for System or when `bundle`
    /// ships no localization. Read by every adopted lookup, so it registers the observation.
    func localizedBundle(for bundle: Bundle) -> Bundle? {
        registrar.access(self, keyPath: \.code)
        let path = bundle.bundlePath
        let (code, known) = state.withLock { ($0.code, $0.localized[path]) }
        guard let code else { return nil }
        if let known { return known }
        // Once per bundle and language: the bundle's directory listing is cached by CFBundle.
        let match = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [code]).first
        let found = match.flatMap { bundle.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:))
        state.withLock { if $0.code == code { $0.localized[path] = .some(found) } }
        return found
    }
}

/// The class an adopted resource bundle takes (``AppLanguage/adopt(_:)``): its strings come from
/// the chosen language's `.lproj`, else from the bundle as before. No stored properties (an
/// instance's class changes in place).
final class AppLanguageBundle: Bundle, @unchecked Sendable { // crash-allow: no stored state; its language is AppLanguage's, behind a Mutex
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let localized = AppLanguage.shared.localizedBundle(for: self) {
            return localized.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    override var preferredLocalizations: [String] {
        if let localized = AppLanguage.shared.localizedBundle(for: self) {
            return [localized.bundleURL.deletingPathExtension().lastPathComponent]
        }
        return super.preferredLocalizations
    }
}
