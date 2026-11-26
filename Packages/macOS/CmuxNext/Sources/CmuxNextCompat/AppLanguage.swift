#if canImport(ObjectiveC)
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
/// A NIGHTLY ships its module bundles in English only and downloads the person's language as a
/// pack on first use (CMUX-570, ``Foundation/Bundle/activateLanguagePack(root:)``): the lookup
/// takes the chosen language's `.lproj` from the pack's copy of the bundle when it has it, else from
/// the bundle; for System it is the pack's copy (the system language's) else the bundle. A pack that
/// becomes active redraws the same way a language change does.
///
/// The bundles learn their language from ``adoptResourceBundles()`` (the ones the launch warm-up
/// opened), through an associated object, so there is no global: the one instance is the app's
/// `AppLanguageApplier`'s. A bundle never adopted (a test's, before the warm-up ends) is itself.
///
/// Live: every ``Foundation/Bundle/inAppLanguage`` read registers ``code`` with Observation, so a
/// SwiftUI body, an `ObservationStream` or a `withObservationTracking` scope that looked up a cmux
/// string runs again when the language changes, with its state kept. The menu bar and the action
/// catalog (command titles) are made once per launch: those take the language at the next launch.
public final class AppLanguage: Observable, Sendable {
    private struct State {
        var code: String?
        /// Each adopted bundle's `.lproj` for ``code``, by bundle path (nil: the bundle has none).
        var localized: [String: Bundle?] = [:]
        /// Counts language changes and pack activations, so a lookup that began before one does not
        /// cache what it found after it.
        var generation = 0
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
            state.withLock { $0 = State(code: code, generation: $0.generation + 1) }
        }
    }

    /// Adopts every SwiftPM resource bundle of the app (`Contents/Resources/*.bundle`), the ones the
    /// launch warm-up opened (``Foundation/Bundle/warmResourceBundlesInBackground(in:)``): no disk
    /// access here. NSBundle keeps one instance per path, so each module's `Bundle.module` is the
    /// adopted one.
    public func adoptResourceBundles() {
        Bundle.forEachWarmedResourceBundle { [self] in adopt($0) }
        Bundle.observeLanguagePacks { [weak self] in self?.languagePackChanged() }
    }

    /// A language pack became active: lookups made under Observation run again and read it.
    func languagePackChanged() {
        registrar.withMutation(of: self, keyPath: \.code) {
            state.withLock { $0.localized = [:]; $0.generation += 1 }
        }
    }

    /// Makes `bundle` (one of cmux's own resource bundles) answer
    /// ``Foundation/Bundle/inAppLanguage`` in this language.
    public func adopt(_ bundle: Bundle) {
        objc_setAssociatedObject(bundle, Self.key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    /// The associated-object key: this class object's address, unique and constant.
    fileprivate static var key: UnsafeRawPointer { unsafeBitCast(AppLanguage.self as AnyClass, to: UnsafeRawPointer.self) }

    /// The `.lproj` bundle for the chosen language from `bundle`'s language pack copy, else from
    /// `bundle` (its development language when neither has that one), nil for System. Registers the
    /// observation of ``code``.
    func localizedBundle(for bundle: Bundle) -> Bundle? {
        registrar.access(self, keyPath: \.code)
        let path = bundle.bundlePath
        let (code, known, generation) = state.withLock { ($0.code, $0.localized[path], $0.generation) }
        guard let code else { return nil }
        if let known { return known }
        // Once per bundle, language and pack: the directory listings are cached by CFBundle.
        let found = (bundle.languagePackCopy.flatMap { Self.lproj(of: $0, for: code, exactly: true) }
            ?? Self.lproj(of: bundle, for: code, exactly: false)).flatMap(Bundle.init(path:))
        state.withLock { if $0.generation == generation { $0.localized[path] = .some(found) } }
        return found
    }

    /// The path of `bundle`'s `.lproj` for `code`. `exactly`: only one of `code`'s language (a pack
    /// holds one language, maybe an earlier choice's); else the best match, the bundle's
    /// development language when it has none of `code`'s.
    private static func lproj(of bundle: Bundle, for code: String, exactly: Bool) -> String? {
        guard let match = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [code]).first else { return nil }
        let (found, wanted) = (Locale(identifier: match).language, Locale(identifier: code).language)
        if exactly, found.languageCode != wanted.languageCode || found.script != wanted.script { return nil }
        return bundle.path(forResource: match, ofType: "lproj")
    }
}

extension Bundle {
    /// This bundle's strings in the app's language: the `.lproj` bundle of the language
    /// `app.language` chose (from the downloaded language pack when it has it), else (System, or a
    /// bundle never adopted) the pack's copy of this bundle, else this bundle. Pass it to
    /// `String(localized:bundle:)`; each module has `Bundle.localizedModule` for its own.
    public var inAppLanguage: Bundle {
        (objc_getAssociatedObject(self, AppLanguage.key) as? AppLanguage)?.localizedBundle(for: self) ?? languagePackCopy ?? self
    }
}
#endif
