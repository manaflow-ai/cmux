import Foundation

/// The CLI uses the enclosing app catalog when packaged, or its sibling resource
/// bundle when built as a standalone Xcode product. A detached executable keeps
/// Foundation's defaultValue behavior. Resolve from the real executable so PATH
/// symlinks do not change resource ownership.
enum CMUXCLILocalization {
    private static let resources = localizationBundle()
    static let bundle = preferredBundle(in: ProcessInfo.processInfo.environment)

    private static func preferredBundle(in environment: [String: String]) -> Bundle {
        guard let localization = explicitLocalization(in: environment, bundle: resources),
              let path = resources.path(forResource: localization, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return resources
        }
        return languageBundle
    }

    static func string(
        _ key: String,
        defaultValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        preferredBundle(in: environment).localizedString(forKey: key, value: defaultValue, table: nil)
    }

    static func localizationBundle(
        mainBundle: Bundle = .main,
        executableURL: URL? = CLIExecutableLocator.currentExecutableURL()
    ) -> Bundle {
        let executableURL = executableURL?.resolvingSymlinksInPath()
        if let app = CLIExecutableLocator.enclosingAppBundle(startingAt: executableURL) {
            return app
        }
        if let resourceURL = executableURL?.deletingLastPathComponent()
            .appendingPathComponent("cmux-cli-resources.bundle"),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }
        return mainBundle
    }

    private static func explicitLocalization(in environment: [String: String], bundle: Bundle) -> String? {
        guard let languages = appleLanguages(from: environment["AppleLanguages"]),
              !languages.isEmpty else {
            return nil
        }

        return Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: languages
        ).first
    }

    private static func appleLanguages(from rawValue: String?) -> [String]? {
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
}
