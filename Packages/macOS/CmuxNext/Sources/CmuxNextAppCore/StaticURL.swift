public import Foundation

/// Fixed URLs the app builds from literals. `URL(string:)` is optional, so a
/// literal goes through `url`, which never traps: a literal that did not
/// parse would become a file URL of the same text. StaticURLTests checks
/// that every case parses, so that fallback is never taken.
public nonisolated enum StaticURL: String, CaseIterable {
    /// cmux's bug report form with its "Additional context" field prefilled: HQ finds reports sent from the app by
    /// that text, so it can count them, link each fix and tell the reporter which nightly has it.
    case feedback = "https://github.com/manaflow-ai/cmux/issues/new?template=bug_report.yml&additional=Sent%20from%20cmux%20NEXT%20Send%20Feedback"
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

    public var url: URL { URL(string: rawValue) ?? URL(fileURLWithPath: rawValue) }
}
