public import Foundation
public import Observation
internal import ObjectiveC

/// The language cmux's own native text is in, switched live (`app.language`, Leo 2026-11-16: "we
/// gotta add settings for changing lanugages"). Which code to use is cmux-config's and the
/// settings snapshot's; this only makes cmux's own string bundles answer in it.
///
/// Every native string is a `String(localized:bundle: .module)` read of a SwiftPM resource bundle
/// (`Contents/Resources/*.bundle`). Each such bundle is adopted (``adoptResourceBundles(in:)``):
/// its class becomes ``AppLanguageBundle``, which answers `localizedString(forKey:value:table:)`
/// from the chosen language's `.lproj`, and with no chosen language (System) exactly as before.
/// Only cmux's own resource bundles are adopted: never `Bundle.main`, a framework or the system's.
/// The bundle reaches its language through an associated object, so there is no global: the one
/// instance is the app's `AppLanguageApplier`'s.
///
/// Live: every lookup reads ``code`` through Observation, so a SwiftUI body, an `ObservationStream`
/// or a `withObservationTracking` scope that looked up a cmux string runs again when the language
/// changes, with its state kept. Text computed outside a tracking scope needs the language read in
/// its observation (the sidebar's sections). The menu bar and the action catalog (command titles)
/// are made once per launch: those take the language at the next launch.
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

    /// Adopts every SwiftPM resource bundle in `resources` (the app's `Contents/Resources`), on a
    /// background thread: the folder listing and a bundle's first open never touch the main thread.
    /// NSBundle keeps one instance per path, so each module's `Bundle.module` is the adopted one.
    public func adoptResourceBundles(in resources: URL? = Bundle.main.resourceURL) {
        let thread = Thread { [self] in
            guard let resources, let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else { return }
            for name in names where name.hasSuffix(".bundle") {
                if let bundle = Bundle(url: resources.appending(path: name, directoryHint: .isDirectory)) { adopt(bundle) }
            }
        }
        thread.name = "cmux-next app language bundles"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Makes `bundle` (one of cmux's own resource bundles) answer in this language. A plain `Bundle`
    /// changes class (``AppLanguageBundle`` adds no stored state, so the instance keeps its layout);
    /// a bundle of another class stays as it is.
    public func adopt(_ bundle: Bundle) {
        let cls: AnyClass? = object_getClass(bundle)
        guard cls == Bundle.self || cls == AppLanguageBundle.self else { return }
        objc_setAssociatedObject(bundle, AppLanguageBundle.languageKey, self, .OBJC_ASSOCIATION_RETAIN)
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
/// its language's `.lproj`, else from the bundle as before. No stored properties (an instance's
/// class changes in place); its ``AppLanguage`` is an associated object.
final class AppLanguageBundle: Bundle, @unchecked Sendable { // crash-allow: no stored state; its language is an AppLanguage, behind a Mutex
    /// The associated-object key: this class object's address, unique and constant.
    static var languageKey: UnsafeRawPointer { unsafeBitCast(AppLanguageBundle.self as AnyClass, to: UnsafeRawPointer.self) }

    private var localized: Bundle? {
        (objc_getAssociatedObject(self, Self.languageKey) as? AppLanguage)?.localizedBundle(for: self)
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let localized { return localized.localizedString(forKey: key, value: value, table: tableName) }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    override var preferredLocalizations: [String] {
        if let localized { return [localized.bundleURL.deletingPathExtension().lastPathComponent] }
        return super.preferredLocalizations
    }
}
