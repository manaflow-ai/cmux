import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation

/// An agent tab the Mac made that has no chat yet (a New Agent Chat tab nobody wrote in) gets its
/// chat from the phone's first send, in that tab (Leo, 2026-11-18: "you should be able to just
/// start the chat right there"): ``startTabChat(tabID:willBind:)`` starts it and binds the tab
/// with `bind-conversation-tab-session` from no session (the phone's lane allows it only from no
/// session: cmux-mobile-host policy). This is the check of whose chat the tab is.
extension LiveWorkspaceCreationBackend {
    /// Whether a tab recorded for `host` starts its chat on this Mac's acpmux: the Mac app's own
    /// `install:<id>` (the host a phone's agent tab gets too), or none recorded.
    nonisolated static func startsHere(host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        return host.hasPrefix("install:")
    }
}
