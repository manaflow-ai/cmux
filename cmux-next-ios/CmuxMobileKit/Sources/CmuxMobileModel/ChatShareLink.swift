import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

/// A chat share link the phone opens: a guest link (`https://share.cmux.dev/g/<id>#<secret>`), an
/// invite (`https://share.cmux.dev/i/<id>`), or the guest page's open-in-app form
/// (`<scheme>://share?link=<page>#<secret>`). The grammar is the Mac daemon's
/// (`cmux-tui-core` `agent_session_share_link.rs`): an id of 16 to 128 URL-safe characters, and a
/// secret of 8 to 128 in the fragment, which no request ever carries.
///
/// The app opens the page signed in as the phone's own cmux account, so the person joins the
/// shared chat as themselves: ``handoffURL`` mints a one-time code for the page with the account's
/// token (cmux-platform `POST /v1/chat-shares/<id>/handoff`), and ``pageURL(handoff:)`` is the page
/// with that code. Only a known share host's page is opened this way; the token never goes to
/// any other host.
///
/// The grammar is Rust's (`cmux-mobile-link-ffi/src/chat_share_link.rs`); where Rust does not
/// link (the macOS and Linux package builds, which have no phone UI) no URL is a share link.
public struct ChatShareLink: Hashable, Sendable {
    /// `g`: a guest link's page; `i`: an invite's.
    public enum Page: String, Hashable, Sendable {
        case guest = "g"
        case invite = "i"
    }

    /// `https://<share host>`, the origin the page and its hand-off are on.
    public let origin: String
    public let page: Page
    public let shareID: String
    /// The guest link's secret (`#<secret>`); nil for an invite, which is joined by account.
    public let secret: String?

    /// The link with these parts, or nil when the id or the secret is malformed.
    public init?(origin: String, page: Page, shareID: String, secret: String?) {
        #if os(iOS)
        guard let parsed = chatShareLinkMake(origin: origin, page: Self.rust(page), shareId: shareID, secret: secret)
        else { return nil }
        self.init(parsed)
        #else
        return nil
        #endif
    }

    /// The share link `url` names, or nil when it is not one (another host, path or scheme, a
    /// malformed id or secret).
    public init?(url: URL) {
        #if os(iOS)
        guard let parsed = chatShareLinkParse(url: url.absoluteString) else { return nil }
        self.init(parsed)
        #else
        return nil
        #endif
    }

    /// Where the phone's account token is spent for a one-time code on this page.
    public var handoffURL: URL {
        #if os(iOS)
        URL(string: chatShareHandoffUrl(link: rust))!
        #else
        preconditionFailure("a share link is made only where Rust links")
        #endif
    }

    /// The page to open: `<origin>/<g|i>/<id>?in_app=1[&cmux_handoff=<code>][#<secret>]`. `in_app=1`
    /// keeps the page from asking the app to open it again; without a code it opens signed out.
    public func pageURL(handoff: String?) -> URL {
        #if os(iOS)
        URL(string: chatSharePageUrl(link: rust, handoff: handoff))!
        #else
        preconditionFailure("a share link is made only where Rust links")
        #endif
    }

    /// An id or hand-off code: 16 to 128 URL-safe characters.
    public static func isID(_ text: String) -> Bool {
        #if os(iOS)
        chatShareIsId(text: text)
        #else
        false
        #endif
    }

    #if os(iOS)
    private init(_ parsed: ParsedChatShareLink) {
        origin = parsed.origin
        page = parsed.page == .guest ? .guest : .invite
        shareID = parsed.shareId
        secret = parsed.secret
    }

    private var rust: ParsedChatShareLink {
        ParsedChatShareLink(origin: origin, page: Self.rust(page), shareId: shareID, secret: secret)
    }

    private static func rust(_ page: Page) -> ChatSharePage {
        switch page {
        case .guest: .guest
        case .invite: .invite
        }
    }
    #endif
}
