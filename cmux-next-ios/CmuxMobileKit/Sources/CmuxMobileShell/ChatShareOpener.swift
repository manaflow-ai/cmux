import CmuxEgress
import CmuxMobileModel
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "chat-share")

/// Opens a chat share link (a guest link, or an invite to someone's shared chat) on the phone as the
/// Mac does (`agent-session-share-open-link`): the page in a Safari view, signed in as this phone's
/// own cmux account so the person joins the chat as themselves.
///
/// Signed in, the account's token buys one one-time code for the page (cmux-platform
/// `POST /v1/chat-shares/<id>/handoff`, a human Stack bearer, never the link's secret); the page
/// spends it on its first load and sets the share join's own cookie in the Safari view. Signed out,
/// or when the share host refuses or does not answer in time, the page opens signed out: a guest
/// link still joins by its secret, and an invite asks the person to sign in there.
enum ChatShareOpener {
    /// How long the hand-off may take before the page opens signed out (the Mac daemon's bound).
    static let handoffTimeout: TimeInterval = 10

    struct Page: Identifiable, Equatable {
        let url: URL
        /// Whether a hand-off code signs the page in as the phone's account.
        let signedIn: Bool
        var id: URL { url }
    }

    /// The page to open for `link`. `token` is the signed-in account's Stack access token, nil
    /// when signed out.
    static func page(for link: ChatShareLink, token: String?,
                     session: URLSession = CmuxEgress.shared(site: "CmuxMobileShell.ChatShareOpener")) async -> Page {
        guard let token, !token.isEmpty else { return Page(url: link.pageURL(handoff: nil), signedIn: false) }
        let code = await mint(link, token: token, session: session)
        log.info("chat share \(link.page.rawValue, privacy: .public) page: hand-off \(code == nil ? "refused" : "minted", privacy: .public)")
        return Page(url: link.pageURL(handoff: code), signedIn: code != nil)
    }

    /// The one-time code for `link`'s page, or nil when the host refuses or does not answer.
    static func mint(_ link: ChatShareLink, token: String, session: URLSession) async -> String? {
        var request = URLRequest(url: link.handoffURL, timeoutInterval: handoffTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["page": link.page.rawValue])
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let answer = try? JSONDecoder().decode(Answer.self, from: data),
              ChatShareLink.isID(answer.handoff) else { return nil }
        return answer.handoff
    }

    private struct Answer: Decodable {
        let handoff: String
    }
}

#if os(iOS)
import SafariServices
import SwiftUI

/// A share page in a Safari view: Safari itself (the person's passkeys, AutoFill and cookies),
/// so the page's sign-in and its guest socket work as they do in Safari. Done closes it.
struct ChatShareSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
