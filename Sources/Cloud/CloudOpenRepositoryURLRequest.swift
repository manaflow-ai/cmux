import CmuxCloud
import Foundation

/// `cmux://cloud/clone?repo=owner/repo&agent=claude&prompt=…`: a link that opens the
/// "Open Repository in Cloud…" sheet prefilled. It never runs anything by itself; the
/// person reads the sheet and presses Open in Cloud. The scheme is the build's own
/// callback scheme (`cmux` for release builds), the same one workspace links use.
struct CloudOpenRepositoryURLRequest: Equatable {
    /// The repository field's text. It may still be invalid; the sheet says why.
    let repository: String
    let agent: CloudOpenRepositoryCommand.Agent?
    let prompt: String?

    static let maxRepositoryLength = 2_048

    /// nil when `url` is not a `<scheme>://cloud/clone` link; a link with no usable
    /// `repo` still opens the sheet, empty, so the person sees what was asked.
    static func parse(
        _ url: URL,
        supportedSchemes: Set<String> = CmuxNavigationURLRequest.activeSupportedSchemes
    ) -> CloudOpenRepositoryURLRequest? {
        guard let scheme = url.scheme?.lowercased(), supportedSchemes.contains(scheme),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "cloud" else { return nil }
        let path = components.path.split(separator: "/").map { $0.lowercased() }
        guard path == ["clone"] else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }
        var repository = value("repo") ?? value("repository") ?? ""
        if repository.count > maxRepositoryLength || CloudOpenRepositoryCommand.containsControlCharacters(repository) {
            repository = ""
        }
        let agent = value("agent").flatMap { CloudOpenRepositoryCommand.Agent(rawValue: $0.lowercased()) }
        return CloudOpenRepositoryURLRequest(
            repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
            agent: agent,
            prompt: agent == nil ? nil : CloudOpenRepositoryCommand.sanitizedPrompt(value("prompt"))
        )
    }

    /// The link for a repository, for docs and "copy link" surfaces.
    static func link(
        repository: String,
        agent: CloudOpenRepositoryCommand.Agent? = nil,
        scheme: String = AuthEnvironment.callbackScheme
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "cloud"
        components.path = "/clone"
        var items = [URLQueryItem(name: "repo", value: repository)]
        if let agent { items.append(URLQueryItem(name: "agent", value: agent.rawValue)) }
        components.queryItems = items
        return components.url
    }
}
