import CmuxNextWindowRules
package import Foundation

/// What a system banner says, built from what the app knows for sure (where) and what the poster
/// said (state and message): title = `workspace › tab [· machine]`, subtitle = the state headline
/// (`Claude finished`, `Needs input`) and the poster's subtitle, body = the message as plain text.
/// The app writes the title, so a terminal program cannot pose as another terminal.
/// (~/fun/cmux-prompts/logs/notifications-DESIGN.md) The rules are Rust's (cmux-window-rules `banner`,
/// ops `window_notifications_banner` and `_plain_text`); this keeps the limits.
package struct NotificationBannerFormatter {
    /// The body's length limit: about four banner lines.
    package var maxBodyCharacters = 240
    /// A workspace or tab name's length limit in the title.
    package var maxNameCharacters = 40

    /// The banner for a notification whose headline is `headline` (the daemon's title, an OSC
    /// 7501 alert's localized title, a burst digest's count). `workspace` nil (no tab in the
    /// store) keeps the headline as the title. `plain` false keeps the body's lines as given
    /// (an approval's command).
    package func content(headline: String, posterSubtitle: String?, body: String, workspace: String?, tab: String?,
                 host: String?, plain: Bool = true) -> NotificationBannerContent {
        struct Request: Encodable {
            var headline: String, posterSubtitle: String?, body: String, workspace: String?, tab: String?, host: String?
            var plain: Bool, maxBodyCharacters: Int, maxNameCharacters: Int
        }
        struct Reply: Decodable { var title: String, subtitle: String?, body: String }
        let request = Request(headline: headline, posterSubtitle: posterSubtitle, body: body, workspace: workspace, tab: tab,
                              host: host, plain: plain, maxBodyCharacters: maxBodyCharacters, maxNameCharacters: maxNameCharacters)
        // An FFI without the op answers nothing: the banner says what the poster said, as given.
        guard let reply = WindowRules().call("window_notifications_banner", request, as: Reply.self) else {
            return NotificationBannerContent(title: headline.isEmpty ? "cmux" : headline, subtitle: posterSubtitle, body: body)
        }
        return NotificationBannerContent(title: reply.title, subtitle: reply.subtitle, body: reply.body)
    }

    /// `markdown` as banner text: no heading, quote or emphasis marks, links and images as their
    /// text, code fences dropped (their code kept), list items as bullets, blank lines removed,
    /// cut on a word to ``maxBodyCharacters`` with an ellipsis.
    package func plainText(_ markdown: String) -> String {
        struct Request: Encodable { var markdown: String, maxBodyCharacters: Int }
        struct Reply: Decodable { var text: String }
        // An FFI without the op answers nothing: the text stays as given.
        return WindowRules().call("window_notifications_plain_text", Request(markdown: markdown, maxBodyCharacters: maxBodyCharacters),
                                  as: Reply.self)?.text ?? markdown
    }

    package init(maxBodyCharacters: Int = 240, maxNameCharacters: Int = 40) {
        self.maxBodyCharacters = maxBodyCharacters
        self.maxNameCharacters = maxNameCharacters
    }
}
