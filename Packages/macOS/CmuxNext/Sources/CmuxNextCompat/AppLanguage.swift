public import Foundation
public import Observation
internal import ObjectiveC

/// The language cmux's own native text is in, switched live (`app.language`, Leo 2026-11-16: "we
/// gotta add settings for changing lanugages"). Which code to use is cmux-config's and the
/// settings snapshot's; this only makes cmux's own string lookups answer in it.
///
/// Every native string is a `String(localized:bundle:)` read of a SwiftPM resource bundle. Each
/// module passes `bundle: .localizedModule` (its `Bundle+AppLanguage.swift`; CmuxNextApp, which
/// takes no new files, writes `.module.inAppLanguage`), which is ``Foundation/Bundle/inAppLanguage``:
/// the module's bundle for System, else that bundle's `.lproj` for the chosen language, which
/// `String(localized:)` reads like any bundle. (Overriding the
/// bundle's `localizedString(forKey:value:table:)` does not work: `String(localized:)` does not
/// call it on macOS 26.)
///
/// The bundles learn their language from ``adoptResourceBundles()`` (the ones the launch warm-up
/// opened), through an associated object, so there is no global: the one instance is the app's
/// `AppLanguageApplier`'s. A bundle never adopted (a test's, before the warm-up ends) is itself.
///
/// Live: every ``Foundation/Bundle/inAppLanguage`` read registers ``code`` with Observation, so a
/// SwiftUI body, an `ObservationStream` or a `withObservationTracking` scope that looked up a cmux
/// string runs again when the language changes, with its state kept. The menu bar and the action
/// catalog (command titles) are made once per launch: those take the language at the next launch.
public final class AppLanguage: Observable, @unchecked Sendable { // crash-allow: its only stored values are a Mutex and the Sendable ObservationRegistrar
    private struct State {
        var code: String?
        /// Each adopted bundle's `.lproj` for ``code``, by bundle path (nil: the bundle has none).
        var localized: [String: Bundle?] = [:]
    }

    private let state = Mutex(State())
    private let registrar = ObservationRegistrar()

    public init() {}

    /// The chosen language (a shipped code such as "ja" or "pt-BR"), nil for System. Observed.
    public var code: String? {
        registrar.access(self, keyPath: \.code)
        return state.withLock { $0.code }
    }

    /// Switches cmux's native text to `code` (nil: System). Views that read a cmux string in an
    /// observation scope run again; the same code again does nothing.
    public func set(_ code: String?) {
        guard state.withLock({ $0.code }) != code else { return }
        registrar.withMutation(of: self, keyPath: \.code) {
            state.withLock { $0 = State(code: code) }
        }
    }

    /// Adopts every SwiftPM resource bundle of the app (`Contents/Resources/*.bundle`), the ones the
    /// launch warm-up opened (``Foundation/Bundle/warmResourceBundlesInBackground(in:)``): no disk
    /// access here. NSBundle keeps one instance per path, so each module's `Bundle.module` is the
    /// adopted one.
    public func adoptResourceBundles() {
        Bundle.forEachWarmedResourceBundle { [self] in adopt($0) }
    }

    /// Makes `bundle` (one of cmux's own resource bundles) answer
    /// ``Foundation/Bundle/inAppLanguage`` in this language.
    public func adopt(_ bundle: Bundle) {
        objc_setAssociatedObject(bundle, Self.key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    /// The associated-object key: this class object's address, unique and constant.
    fileprivate static var key: UnsafeRawPointer { unsafeBitCast(AppLanguage.self as AnyClass, to: UnsafeRawPointer.self) }

    /// The `.lproj` bundle of `bundle` for the chosen language (its development language when it
    /// does not ship that one), nil for System. Registers the observation of ``code``.
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

extension Bundle {
    /// This bundle's strings in the app's language: the `.lproj` bundle of the language
    /// `app.language` chose, else (System, or a bundle never adopted) this bundle. Pass it to
    /// `String(localized:bundle:)`; each module has `Bundle.localizedModule` for its own.
    public var inAppLanguage: Bundle {
        (objc_getAssociatedObject(self, AppLanguage.key) as? AppLanguage)?.localizedBundle(for: self) ?? self
    }
}
