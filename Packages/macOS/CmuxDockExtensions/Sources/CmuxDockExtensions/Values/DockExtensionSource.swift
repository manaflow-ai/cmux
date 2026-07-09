import Foundation

/// Where an extension came from: a GitHub repo (herdr-style
/// `owner/repo[/subdir]` shorthand, the only remote install form) or a local
/// directory registered for development via `link`.
///
/// Encodes as the shorthand string for GitHub sources and `{"path": …}` for
/// linked sources, so the `~/.config/cmux/extensions.json` lockfile stays
/// human-readable.
public enum DockExtensionSource: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// A public GitHub repository, optionally a subdirectory within it.
    case github(owner: String, repository: String, subdirectory: String?)
    /// A local directory linked for development; never built, never pinned.
    case local(path: String)

    /// Parses user input into a GitHub source. Accepts `owner/repo`,
    /// `owner/repo/sub/dir`, and full `https://github.com/owner/repo(.git)`
    /// URLs (with optional `/tree/<ref>/<subdir>` suffixes rejected — the ref
    /// belongs in `--ref`). Returns `nil` for anything else.
    public static func parseGitHub(_ input: String) -> DockExtensionSource? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"] {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        let components = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else { return nil }

        let owner = components[0]
        var repository = components[1]
        if repository.lowercased().hasSuffix(".git") {
            repository = String(repository.dropLast(4))
        }
        guard isValidOwner(owner), isValidRepository(repository) else { return nil }

        let subdirectoryComponents = Array(components.dropFirst(2))
        // Browser URLs paste as `owner/repo/tree/<ref>/<subdir>`; "tree" is
        // GitHub's UI path segment, not a repo directory. Reject it instead of
        // silently treating `tree/<ref>/…` as the manifest subdirectory (the
        // ref belongs in `--ref`).
        guard subdirectoryComponents.first != "tree" else { return nil }
        guard subdirectoryComponents.allSatisfy({ isValidSubdirectoryComponent($0) }) else { return nil }
        let subdirectory = subdirectoryComponents.isEmpty ? nil : subdirectoryComponents.joined(separator: "/")
        return .github(owner: owner, repository: repository, subdirectory: subdirectory)
    }

    /// The `owner/repo[/subdir]` shorthand (GitHub) or the linked path.
    public var description: String {
        switch self {
        case .github(let owner, let repository, let subdirectory):
            if let subdirectory {
                return "\(owner)/\(repository)/\(subdirectory)"
            }
            return "\(owner)/\(repository)"
        case .local(let path):
            return path
        }
    }

    /// The HTTPS clone URL for GitHub sources; `nil` for linked directories.
    public var cloneURLString: String? {
        switch self {
        case .github(let owner, let repository, _):
            return "https://github.com/\(owner)/\(repository).git"
        case .local:
            return nil
        }
    }

    /// The browsable repository page for GitHub sources.
    public var webURL: URL? {
        switch self {
        case .github(let owner, let repository, _):
            return URL(string: "https://github.com/\(owner)/\(repository)")
        case .local:
            return nil
        }
    }

    /// The manifest subdirectory inside the checkout, if any.
    public var subdirectory: String? {
        switch self {
        case .github(_, _, let subdirectory):
            return subdirectory
        case .local:
            return nil
        }
    }

    /// Whether this is a linked local development source.
    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    private static func isValidOwner(_ owner: String) -> Bool {
        guard (1...39).contains(owner.count) else { return false }
        return owner.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    private static func isValidRepository(_ repository: String) -> Bool {
        guard (1...100).contains(repository.count) else { return false }
        return repository.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func isValidSubdirectoryComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component.count <= 128, component != "..", component != "." else { return false }
        return !component.contains("\0")
    }
}

extension DockExtensionSource: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let shorthand = try? container.decode(String.self) {
            guard let source = DockExtensionSource.parseGitHub(shorthand) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "not a valid owner/repo[/subdir] extension source: \(shorthand)"
                )
            }
            self = source
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        self = .local(path: try object.decode(String.self, forKey: .path))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .github:
            var container = encoder.singleValueContainer()
            try container.encode(description)
        case .local(let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case path
    }
}
