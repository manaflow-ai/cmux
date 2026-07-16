import Foundation

struct AboutLicenseContent {
    static let repositoryURL = URL(string: "https://github.com/manaflow-ai/cmux")!

    static func load(from bundle: Bundle) -> String {
        let missingMessage = String(
            localized: "about.licenses.notFound",
            defaultValue: "Licenses file not found.",
            bundle: bundle
        )
        let projectLicense = resourceText(
            named: "LICENSE",
            fileExtension: nil,
            in: bundle
        ) ?? missingMessage
        let thirdPartyLicenses = resourceText(
            named: "THIRD_PARTY_LICENSES",
            fileExtension: "md",
            in: bundle
        ) ?? missingMessage
        let projectHeading = String(
            localized: "about.licenses.projectHeading",
            defaultValue: "cmux Project License",
            bundle: bundle
        )
        let projectSourceLabel = String(
            localized: "about.licenses.projectSource",
            defaultValue: "Project source",
            bundle: bundle
        )
        let correspondingSourceLabel = String(
            localized: "about.licenses.correspondingSource",
            defaultValue: "Corresponding source for this build",
            bundle: bundle
        )

        return """
        # \(projectHeading)

        \(projectSourceLabel): \(repositoryURL.absoluteString)
        \(correspondingSourceLabel): \(correspondingSourceURL(in: bundle).absoluteString)

        \(projectLicense)

        ---

        \(thirdPartyLicenses)
        """
    }

    static func correspondingSourceURL(in bundle: Bundle) -> URL {
        correspondingSourceURL(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundleIdentifier: bundle.bundleIdentifier,
            commit: bundle.object(forInfoDictionaryKey: "CMUXCommit") as? String
        )
    }

    static func correspondingSourceURL(
        version: String?,
        bundleIdentifier: String?,
        commit: String?
    ) -> URL {
        if bundleIdentifier == "com.cmuxterm.app", let version = normalized(version) {
            return repositoryURL
                .appendingPathComponent("tree", isDirectory: true)
                .appendingPathComponent("v\(version)")
        }
        if let commit = normalized(commit) {
            return repositoryURL
                .appendingPathComponent("tree", isDirectory: true)
                .appendingPathComponent(commit)
        }
        return repositoryURL
    }

    private static func resourceText(
        named name: String,
        fileExtension: String?,
        in bundle: Bundle
    ) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
