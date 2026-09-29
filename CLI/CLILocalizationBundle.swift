import Foundation

extension Bundle {
    /// The bundle every CLI `String(localized:)` call passes as `bundle:`.
    ///
    /// The bundled CLI runs from `cmux.app/Contents/Resources/bin/cmux`, where
    /// `Bundle.main` is the `bin` directory and has no localizations. The CLI
    /// string table (`Resources/Localizable.xcstrings`) compiles into the app's
    /// `.lproj` folders, so the CLI localizes from the enclosing app bundle.
    static let cmuxCLI: Bundle = CLILocalizationBundle.resolve()
}

enum CLILocalizationBundle {
    /// The enclosing app bundle, or `mainBundle` for a CLI outside an app.
    /// A non-empty `AppleLanguages` environment variable (`(ja)` or `ja,en`)
    /// selects that language's `.lproj` directly, the same override
    /// ``CMUXDiffViewerLocalization`` honors; it lets scripts and smoke tests
    /// pick a language without changing the user's defaults. Without it, an
    /// explicit POSIX message locale (`LC_ALL`, then `LC_MESSAGES`) selects
    /// the language; `C`, `POSIX` or neither variable keeps the user's macOS
    /// language order. Plain `LANG` is ignored: terminals set it by default
    /// (often `en_US.UTF-8` whatever the macOS language), so honoring it
    /// would silently switch non-English users to English.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = CLIExecutableLocator.currentExecutableURL(),
        mainBundle: Bundle = .main
    ) -> Bundle {
        let bundle = CLIExecutableLocator.enclosingAppBundle(startingAt: executableURL) ?? mainBundle
        guard let languages = languages(fromAppleLanguages: environment["AppleLanguages"])
                // An unshipped POSIX language falls back to the user's order.
                ?? languages(fromPOSIXLocale: environment).map({ $0 + Locale.preferredLanguages }),
              let localization = Bundle.preferredLocalizations(
                  from: bundle.localizations,
                  forPreferences: languages
              ).first,
              let path = bundle.path(forResource: localization, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return bundle
        }
        return languageBundle
    }

    static func languages(fromAppleLanguages rawValue: String?) -> [String]? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("("), value.hasSuffix(")") {
            value.removeFirst()
            value.removeLast()
        }
        let languages = value
            .split(separator: ",")
            .map { piece in
                piece
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
        return languages.isEmpty ? nil : languages
    }

    /// The language of the first non-empty `LC_ALL` or `LC_MESSAGES`
    /// (`de_DE.UTF-8` -> `de-DE`, `sr_RS@latin` -> `sr-RS`), or nil when that
    /// variable names the `C`/`POSIX` locale or neither is set. `LANG` is
    /// deliberately not read (see ``resolve(environment:executableURL:mainBundle:)``).
    static func languages(fromPOSIXLocale environment: [String: String]) -> [String]? {
        let rawValue = ["LC_ALL", "LC_MESSAGES"]
            .lazy
            .compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let rawValue else { return nil }
        let name = rawValue
            .prefix { $0 != "." && $0 != "@" }
            .replacingOccurrences(of: "_", with: "-")
        guard !name.isEmpty, name != "C", name != "POSIX" else { return nil }
        return [name]
    }
}
