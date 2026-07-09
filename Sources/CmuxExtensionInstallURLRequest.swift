import CmuxDockExtensions
import Foundation

/// A legacy `cmux://extensions/install?repo=owner/repo[&subdir=…][&ref=…]`
/// deep link. Parsing never installs anything: a valid request only opens the
/// consent window, where the exact pinned commit and commands are reviewed
/// like any other install.
struct CmuxExtensionInstallURLRequest: Equatable {
    /// Reasons a recognized `extensions/install` link is rejected.
    enum ParseError: Error, Equatable {
        case unsupportedURLShape
        case missingRepo
        case invalidRepo(String)
        case invalidRef(String)
    }

    /// The dev/nightly/release cmux callback scheme currently active.
    static var activeSupportedSchemes: Set<String> {
        [AuthEnvironment.callbackScheme.lowercased()]
    }

    let originalURL: URL
    /// The `owner/repo[/subdir]` install input (query `repo` plus optional
    /// `subdir` joined), pre-validated as a GitHub source.
    let source: String
    /// Optional branch/tag/SHA to pin (`--ref` equivalent).
    let ref: String?

    /// Parses a URL. `.success(nil)` means "not an extensions-install link";
    /// `.failure` means it is one, but malformed — callers show an error and
    /// never fall through to other URL families.
    static func parse(
        _ url: URL,
        supportedSchemes: Set<String> = activeSupportedSchemes
    ) -> Result<CmuxExtensionInstallURLRequest?, ParseError> {
        guard let scheme = url.scheme?.lowercased(), supportedSchemes.contains(scheme) else {
            return .success(nil)
        }
        guard (url.host ?? "").lowercased() == "extensions" else {
            return .success(nil)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unsupportedURLShape)
        }
        let pathSegments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
        guard pathSegments == ["install"] else {
            return .failure(.unsupportedURLShape)
        }
        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedFragment == nil else {
            return .failure(.unsupportedURLShape)
        }

        var repo: String?
        var subdir: String?
        var ref: String?
        for item in components.queryItems ?? [] {
            let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch item.name.lowercased() {
            case "repo":
                repo = value
            case "subdir":
                subdir = value
            case "ref":
                ref = value
            default:
                // Unknown parameters are rejected rather than ignored so a
                // crafted link can't smuggle inputs past the consent copy.
                return .failure(.unsupportedURLShape)
            }
        }

        guard let repo, !repo.isEmpty else {
            return .failure(.missingRepo)
        }
        guard repo.count <= 300, subdir.map({ $0.count <= 300 }) ?? true else {
            return .failure(.invalidRepo(repo))
        }
        var source = repo
        if let subdir, !subdir.isEmpty {
            source += "/" + subdir
        }
        guard DockExtensionSource.parseGitHub(source) != nil else {
            return .failure(.invalidRepo(source))
        }

        if let candidate = ref, !candidate.isEmpty {
            guard candidate.count <= 128, Self.isValidRef(candidate) else {
                return .failure(.invalidRef(candidate))
            }
            ref = candidate
        } else {
            ref = nil
        }

        return .success(CmuxExtensionInstallURLRequest(originalURL: url, source: source, ref: ref))
    }

    /// Builds an install link (used by tests and mirrored by the web gallery).
    static func installLink(
        source: String,
        ref: String? = nil,
        scheme: String = AuthEnvironment.callbackScheme
    ) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "extensions"
        components.path = "/install"
        var queryItems = [URLQueryItem(name: "repo", value: source)]
        if let ref { queryItems.append(URLQueryItem(name: "ref", value: ref)) }
        components.queryItems = queryItems
        return components.string ?? "\(scheme)://extensions/install?repo=\(source)"
    }

    private static func isValidRef(_ ref: String) -> Bool {
        ref.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "/", "-":
                return true
            default:
                return false
            }
        }
    }
}
