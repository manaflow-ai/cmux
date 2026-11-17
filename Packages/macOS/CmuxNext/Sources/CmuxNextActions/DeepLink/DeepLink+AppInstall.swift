public import Foundation

nonisolated extension DeepLink {
    /// The action an app install link runs: `cmux://apps/install?repo=github.com/OWNER/REPO[/PATH]`
    /// with an optional `&commit=<40 hex>` (else `&ref=<ref>`) is `app.install` with
    /// `app` = the repo and `@` plus the commit or ref, the same action as `cmux apps install
    /// <reference>`. That action always shows the App Store's consent card, so a link never
    /// installs by itself. The repo is checked loosely here; the daemon reads the reference.
    /// - Parameters:
    ///   - url: The clicked or opened link.
    ///   - linkScheme: This build's own scheme; the `cmux` scheme is taken too.
    /// - Returns: The action and its arguments, or nil for any other URL or a malformed one
    ///   (no repo, a repeated parameter, whitespace, more than 512 characters, an `@` in a repo
    ///   that also names a commit or ref).
    public static func appInstallAction(for url: URL, linkScheme: String) -> SettingsLinkAction? {
        guard let scheme = url.scheme?.lowercased(), scheme == "cmux" || scheme == linkScheme.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "apps", components.path.lowercased() == "/install",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { return nil }
        let query = components.queryItems ?? []
        // One value per name, so a link never has two readings; an empty value is no value.
        func one(_ name: String) -> String?? {
            let items = query.filter { $0.name == name }
            guard items.count <= 1 else { return nil }
            guard let value = items.first?.value, !value.isEmpty else { return .some(nil) }
            return .some(value)
        }
        guard let repoItem = one("repo"), let repo = repoItem, isAppReferencePart(repo),
              let commit = one("commit"), let ref = one("ref") else { return nil }
        // A commit that is not 40 hex digits is read as a ref; the daemon resolves either.
        guard let version = commit ?? ref else {
            return SettingsLinkAction("app.install", arguments: ["app": .string(repo)])
        }
        guard isAppReferencePart(version), !repo.contains("@"), !version.contains("@") else { return nil }
        let pinned = isCommit(version) ? version.lowercased() : version
        return SettingsLinkAction("app.install", arguments: ["app": .string(repo + "@" + pinned)])
    }

    /// The longest repo or ref an app install link carries.
    static let appReferenceMaxLength = 512

    /// A repo or ref of an app install link: 1 to 512 characters, none of them whitespace or a
    /// control character.
    static func isAppReferencePart(_ text: String) -> Bool {
        (1...appReferenceMaxLength).contains(text.count)
            && text.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    /// A full git commit id: 40 hex digits.
    static func isCommit(_ text: String) -> Bool {
        text.utf8.count == 40 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }
}
