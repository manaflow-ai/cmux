import Foundation

/// The CLI can be installed without SwiftPM's resource bundle. The generated
/// Bundle.module accessor traps in that layout, before a fallback can be used.
enum CmuxFoundationLocalization {
    private final class BundleAnchor {}

    static let bundle: Bundle? = findBundle(in: [
        Bundle.main.resourceURL,
        Bundle.main.bundleURL,
        Bundle.main.bundleURL.deletingLastPathComponent(),
        Bundle(for: BundleAnchor.self).resourceURL,
        Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent(),
    ].compactMap { $0 })

    static func findBundle(in directories: [URL]) -> Bundle? {
        for directory in directories {
            let url = directory.appendingPathComponent("CmuxFoundation_CmuxFoundation.bundle")
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }

    static func string(
        _ key: StaticString,
        defaultValue: String,
        bundle: Bundle? = CmuxFoundationLocalization.bundle
    ) -> String {
        guard let bundle else { return defaultValue }
        return String(
            localized: key,
            defaultValue: String.LocalizationValue(stringLiteral: defaultValue),
            bundle: bundle
        )
    }
}
