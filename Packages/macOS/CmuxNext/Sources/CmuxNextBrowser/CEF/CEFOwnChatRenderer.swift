import Foundation

/// Gives the agent chat the person types in a renderer of its own; every other chat keeps sharing one.
///
/// Every agent chat is `cmux-page://cmux.agent/`, and the fork runs one renderer per site for cmux pages
/// (`CEFSwitches.processPerSitePageSchemes`, a memory decision: 100 chats held 107 renderers and 17.5 GB
/// before). A key typed in one chat then waited on that renderer's main thread behind every other chat's
/// stream work: key to the page's listener p95 31-37 ms on cmux20-bench while the app's main thread was
/// mostly idle.
///
/// The most recently focused agent chat is named to the shim (`cmux_shim_page_own_renderer`), which answers
/// that browser's chat document with `Cross-Origin-Opener-Policy: same-origin` and
/// `Cross-Origin-Embedder-Policy: credentialless` (`OwnRendererHeaders`, cmux_page_path.h). Chromium keys a
/// site's one renderer by the whole site info, which includes cross-origin isolation, so that document runs
/// in the site's isolated renderer: one more renderer, never more, however many documents were ever answered
/// so. The rest keep sharing. (Not `Origin-Agent-Cluster`: on a cmux-page origin it hits a Chromium CHECK.)
///
/// A document cannot move between renderers, so the choice takes effect on the chat's next load: a new
/// chat, a restore, a reload or a hibernated chat waking up. Focus moving to a chat already loaded does not
/// reload it; that chat moves on its next load, and the chat that had the renderer leaves it on its own.
@MainActor
final class CEFOwnChatRenderer {
    /// The page host of agent chats (`PageEnginePolicy.agentPageID`, the shim's `kOwnRendererPageId`).
    static let chatHost = "cmux.agent"

    private var owner: ObjectIdentifier?
    /// The browser last named to the shim; 0 for none.
    private(set) var named: Int32 = 0
    private let name: @MainActor (Int32) -> Void

    init(name: @escaping @MainActor (Int32) -> Void) {
        self.name = name
    }

    static func isAgentChat(_ url: URL?) -> Bool {
        url?.scheme == "cmux-page" && url?.host == chatHost
    }

    /// A page was given focus. An agent chat becomes the owner; any other page leaves the owner as it is.
    /// A chat focused before its browser exists is named once it does (``attached(_:browser:)``).
    func focused(_ page: ObjectIdentifier, url: URL?, browser: Int32?) {
        guard Self.isAgentChat(url) else { return }
        owner = page
        update(browser ?? 0)
    }

    /// A page's browser exists (`CEFTab.attach`), in the turn that created it: the shim decides the chat's
    /// document after that turn, so the owner's first load already gets its renderer.
    func attached(_ page: ObjectIdentifier, browser: Int32) {
        guard page == owner else { return }
        update(browser)
    }

    private func update(_ browser: Int32) {
        guard browser != named else { return }
        named = browser
        name(browser)
    }
}
