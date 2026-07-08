import Foundation

/// Builds the prefilled GitHub issue URL for supported-extension submissions.
struct CmuxExtensionSubmitIssueURL {
    static func build(
        source: String,
        pinnedSha: String?,
        name: String?,
        version: String?,
        description: String?,
        ref: String?,
        validationOutput: String?
    ) -> URL {
        let parsed = splitSource(source)
        let validation = validationOutput ?? defaultValidationOutput(
            source: source,
            pinnedSha: pinnedSha,
            name: name,
            version: version,
            ref: ref
        )
        var queryItems: [(String, String)] = [
            ("template", "extension-submission.yml"),
            ("repo", parsed.repo),
            ("pinned-sha", pinnedSha ?? ""),
            ("description", description ?? name ?? ""),
            ("validation", validation),
        ]
        if let subdirectory = parsed.subdirectory {
            queryItems.insert(("subdirectory", subdirectory), at: 2)
        }

        let query = queryItems
            .map { "\($0.0)=\(percentEncodeQueryValue($0.1))" }
            .joined(separator: "&")
        return URL(string: "https://github.com/manaflow-ai/cmux/issues/new?\(query)")!
    }

    private static func splitSource(_ source: String) -> (repo: String, subdirectory: String?) {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 2 else {
            return (source, nil)
        }
        return (parts[0] + "/" + parts[1], parts.dropFirst(2).joined(separator: "/"))
    }

    private static func defaultValidationOutput(
        source: String,
        pinnedSha: String?,
        name: String?,
        version: String?,
        ref: String?
    ) -> String {
        var lines = [
            "cmux extension submit \(source)\(ref.map { " --ref \($0)" } ?? "")",
            "Repository: \(source)",
            "Pinned SHA: \(pinnedSha ?? "")",
        ]
        if let name, !name.isEmpty {
            lines.append("Name: \(name)")
        }
        if let version, !version.isEmpty {
            lines.append("Version: \(version)")
        }
        return lines.joined(separator: "\n")
    }

    private static func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
