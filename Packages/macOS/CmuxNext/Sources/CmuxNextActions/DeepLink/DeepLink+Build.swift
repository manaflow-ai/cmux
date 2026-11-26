public import Foundation

// Fork and customize (cmux.com's button on an extension page): `cmux://build?remix=REF` opens a
// new agent chat whose composer holds the ask to remix REF, unsent, so the person adds what to
// change and presses Return. The work is the Rust CLI's (`cmux ext remix`, `cmux ext share`,
// cmux-tui `cli/ext/remix.rs`); this file only reads the link. REF is the install reference
// `HOST/OWNER/REPO[/PATH][@COMMIT]`: a link from a public page never puts other text in the
// composer, and anything outside that grammar opens nothing.

extension DeepLink {
    /// The link host of Fork and customize.
    public static let buildHost = "build"

    /// The composer draft `cmux://build?remix=REF` (in the `cmux` scheme or `linkScheme`) opens a
    /// new agent chat with; nil for any other URL, a link with no or two `remix` values, or a REF
    /// outside the reference grammar.
    public static func buildDraft(for url: URL, linkScheme: String) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == chiefScheme || scheme == linkScheme.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == buildHost, components.path.isEmpty || components.path == "/",
              components.user == nil, components.port == nil, components.fragment == nil else { return nil }
        // Only `remix`, once: a link with anything else is outside the grammar.
        let refs = components.queryItems ?? []
        guard refs.count == 1, let item = refs.first, item.name == "remix", let ref = item.value, isRemixReference(ref) else { return nil }
        return remixDraft(ref)
    }

    /// The action New Agent Chat runs under (`palette.newAgentChat`), which takes the `draft`.
    public static let buildChatAction: ActionID = "palette.newAgentChat"

    /// The action a link runs as the person's click, from inside cmux or another app: a settings
    /// link's (``settingsAction(for:linkScheme:)``), or Fork and customize's New Agent Chat with
    /// the remix ask as its draft. Nil for any other URL.
    public static func linkAction(for url: URL, linkScheme: String) -> SettingsLinkAction? {
        if let settings = settingsAction(for: url, linkScheme: linkScheme) { return settings }
        return buildDraft(for: url, linkScheme: linkScheme).map { SettingsLinkAction(buildChatAction, arguments: ["draft": .string($0)]) }
    }

    /// The ask a remix link puts in the composer (agent text, never shown as interface copy).
    public static func remixDraft(_ ref: String) -> String {
        "Fork and customize \(ref): run `cmux ext remix \(ref)` and do what it prints. What I want changed: "
    }

    /// `HOST/OWNER/REPO[/PATH]@REF` (the button pins the listing's commit), optionally after `https://`: letters, digits, `.`, `_`, `-`
    /// in each part, no `..`, at most 300 characters.
    public static func isRemixReference(_ text: String) -> Bool {
        let pattern = "^(https?://)?[a-z0-9-]+(\\.[a-z0-9-]+)+(/[A-Za-z0-9._-]+){2,}@[A-Za-z0-9._/-]+$"
        // No line break: `$` also matches before a final newline a decoded `%0A` could leave.
        return text.utf8.count <= 300 && !text.contains("..") && !text.contains(where: \.isNewline)
            && text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
