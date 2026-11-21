import CmuxNextWakeups
import Foundation

extension PageWebView {
    /// Runs `body` once the current document has painted its first frame
    /// (``PagePaintProbe``), now if it has. A pane keeps its outgoing content
    /// until then (no-flicker audit).
    public func whenPainted(_ body: @escaping () -> Void) {
        if hasPainted { body() } else { paintWaiters.append(body) }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension PageWebView {
    /// A ``ChatOpenTrace`` mark of this page, when it is an agent chat's page.
    func traceMark(_ mark: ChatOpenTrace.Mark) {
        guard ChatOpenTrace.shared.isArmed, descriptor.id == ChatOpenTrace.agentPageID else { return }
        ChatOpenTrace.shared.mark(mark, page: self)
    }
}
#endif

extension PageWebView {
    /// The App's launch marks (`DebugTimings.markLaunch`: milliseconds since the process started, the first time of
    /// each name kept), installed at launch; nil in tests.
    public static var launchMark: ((String) -> Void)?
    /// The agent chat page that owns the `chat_page.*` launch marks: the first one to mark.
    private static var launchChat: ObjectIdentifier?

    /// Marks `chat_page.<step>` (`setup_done`, `committed`, `painted`) as a launch mark in every build, for the
    /// agent chat page that marks first (the chat in front at a relaunch): it splits the stretch from Chromium's
    /// browser made (`chromium_page.browser_created`) to the chat drawn (`agent_pane.painted`) in nightly launch
    /// data, which ``ChatOpenTrace`` splits only in DEBUG and bench builds. Each name once; no other page marks.
    func chatLaunchMark(_ step: String) {
        guard descriptor.isAgentPage, let mark = Self.launchMark else { return }
        let page = ObjectIdentifier(self)
        if Self.launchChat == nil { Self.launchChat = page }
        guard Self.launchChat == page else { return }
        mark("chat_page." + step)
    }
}
