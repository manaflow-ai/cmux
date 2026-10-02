public import Foundation

/// A CmuxNext target's SwiftPM resource bundle, found without trapping.
///
/// SwiftPM's generated `Bundle.module` traps when the bundle is missing, which
/// happens when the app's folder is deleted while it still runs. This looks
/// in the same places (the app's resources, beside the code, and beside a
/// `swift test` bundle) and holds nil instead, so localized text falls back
/// to its English source string.
public nonisolated struct ModuleResourceBundle: Sendable {
    /// The resource bundle, or nil when no search directory holds it.
    public let bundle: Bundle?

    /// Looks for `<name>.bundle` in each directory; the first match wins.
    public init(name: String, searchDirectories: [URL]) {
        bundle = searchDirectories.lazy
            .compactMap { Bundle(url: $0.appending(path: "\(name).bundle", directoryHint: .isDirectory)) }
            .first
    }

    /// The bundle of `target` in the CmuxNext package. `anchor` is a class
    /// compiled into that target, locating its code the way `Bundle.module` does.
    public init(cmuxNextTarget target: String, anchor: AnyClass) {
        let code = Bundle(for: anchor)
        self.init(
            name: "CmuxNext_\(target)",
            searchDirectories: [
                Bundle.main.resourceURL,
                code.resourceURL,
                Bundle.main.bundleURL,
                // `swift test` puts module bundles beside the .xctest bundle.
                code.bundleURL.deletingLastPathComponent(),
            ].compactMap { $0 }
        )
    }

    /// The localized value of `key`, or `defaultValue` (English) when the
    /// bundle is gone.
    public func text(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        guard let bundle else {
            // A table no bundle has, so the lookup returns the default value.
            return String(localized: key, defaultValue: defaultValue, table: Self.missingTable, bundle: .main)
        }
        return String(localized: key, defaultValue: defaultValue, bundle: bundle)
    }

    private static let missingTable = "CmuxNextMissingResourceBundle"
}
