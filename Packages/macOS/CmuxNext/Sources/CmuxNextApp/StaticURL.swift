import Foundation

/// Fixed URLs the app builds from literals. `URL(string:)` is optional, so a
/// literal goes through `url`, which never traps: a literal that did not
/// parse would become a file URL of the same text. StaticURLTests checks
/// that every case parses, so that fallback is never taken.
nonisolated enum StaticURL: String, CaseIterable {
    case feedback = "https://github.com/manaflow-ai/cmux/issues/new"
    case documentation = "https://cmux.com/docs"
    case pricing = "https://cmux.com/pricing"
    /// Help > Troubleshooting and Support: docs, Discord, GitHub issues and email in one page.
    case support = "https://cmux.com/support"
    /// The cmux Discord (Manaflow's server; the invite README.md and cmux.com link).
    case discord = "https://discord.gg/xsgFEVrWCZ"
    /// cmux's own X account, @cmux (user 2026-10-27: "we have @cmux now").
    case x = "https://x.com/cmux"
    case github = "https://github.com/manaflow-ai/cmux"
    case blank = "about:blank"

    var url: URL { URL(string: rawValue) ?? URL(fileURLWithPath: rawValue) }
}
