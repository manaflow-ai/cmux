import CmuxNextCompat
import CmuxNextDesign
import Foundation

/// The warm chat page pool (CMUX-1005), off by default: a constant number of cmux chat pages (default 2)
/// with the chat bundle loaded, made at idle moments in the cmux pages' spare window
/// (`CEFRuntime.pageSpareWindow`, as the spare page of `CEFPaneHost+SparePage` and PR #56555's parked chat
/// view). A sidebar hover over a chat workspace or tab points one of them at that session with the page RPC
/// `cmux.agent.pool.retarget { session }` (webviews `agent-session/acpmux/poolRetarget.ts`) instead of
/// prewarming a page per hover; a click adopts the page that shows it and the pool refills at the next idle.
///
/// The rules (latest hover wins, 80 ms debounce, reuse the page showing the session, else an idle page, else
/// the least recently used one; adopt only a ready page) are the Rust crate `cmux-chat-page-pool`, per
/// `.github/language-boundaries.toml`. This file is only the host: it feeds hover, click, idle and ready
/// events in and applies the effects (make a page, send the RPC, hand a page to a pane, close one).
///
/// DRAFT: the FFI (`cmux-app-ffi` `chat_page_pool`), the sidebar hover hook and the pane adoption are not yet
/// wired; with the setting off (the default) nothing here runs.
final class CEFChatPagePool {
    /// Debug Settings > Browser Page Loading > "Keep warm chat pages for sidebar hovers". Off by default.
    nonisolated static let setting = Tunable<Bool>.toggle(
        "browserPage.chatPagePool", BrowserPageTunables.section, "Keep warm chat pages for sidebar hovers",
        help: "Two chat pages are kept loaded in the background. Resting the pointer on a chat in the sidebar points one at that chat, so clicking it opens at once. Off makes each chat's page when it opens.",
        default: false, code: "CEFChatPagePool.setting")
    static var isOn: Bool { setting.value }

    /// The pool's size when on (`cmux_chat_page_pool::DEFAULT_CAPACITY`).
    static let capacity = 2
    /// The page RPC a hover sends into a pool page's JS.
    static let retargetOp = "cmux.agent.pool.retarget"
}
