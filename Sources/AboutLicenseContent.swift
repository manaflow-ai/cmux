import Foundation

struct AboutLicenseContent {
    let bundle: Bundle
    let repositoryURL: URL

    init(
        bundle: Bundle,
        repositoryURL: URL = URL(string: "https://github.com/manaflow-ai/cmux")!
    ) {
        self.bundle = bundle
        self.repositoryURL = repositoryURL
    }

    func load() -> String {
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
        \(correspondingSourceLabel): \(correspondingSourceURL().absoluteString)

        \(projectLicense)

        ---

        \(thirdPartyLicenses)
        """
    }

    func correspondingSourceURL() -> URL {
        correspondingSourceURL(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundleIdentifier: bundle.bundleIdentifier,
            commit: bundle.object(forInfoDictionaryKey: "CMUXCommit") as? String
        )
    }

    func correspondingSourceURL(
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

    private func resourceText(
        named name: String,
        fileExtension: String?,
        in bundle: Bundle
    ) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
