public import AppKit
public import CmuxNextWakeups

/// Holds the launch's New Tab spare (CmuxNextApp's `NewTabSparePool`) until the restored chat pages on screen
/// drew their first frame, or ``deadline``. Made beside them, the spare's page loaded in WebKit at the same time,
/// and when it went first the shown chat drew about 0.7 s later (L5 relaunch on a NIGHTLY, cmux20, 2026-11-09:
/// 1814 ms against 1094 ms). Checked once per run, over the pages on screen only, so its cost does not grow with
/// the open tabs.
///
/// ```swift
/// if launch, shownChats.holds({ AgentPaneShownChatsWait.loading(agentTabs.views.values) }, then: armWarmTimer) { return }
/// ```
@MainActor
public final class AgentPaneShownChatsWait {
    /// Runs its body once a page drew its first frame (`AgentPaneModel.whenPainted`).
    public typealias WhenPainted = (@escaping () -> Void) -> Void

    /// The longest a page that never reports its paint holds the spare.
    public static let deadline: Duration = .seconds(3)

    private var pending = 0
    private var checked = false
    private let timer: DemandTimer

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "NewTabSparePool.shownChats", clock: clock)
    }

    /// True while a wait holds the spare: the first call reads `loading` and waits on each page; `then` runs once
    /// the last drew or the deadline passed. A call after that wait ended returns false.
    public func holds(_ loading: () -> [WhenPainted], then: @escaping @MainActor () -> Void) -> Bool {
        if pending > 0 { return true }
        guard !checked else { return false }
        checked = true
        let pages = loading()
        pending = pages.count
        var asking = true
        for whenPainted in pages {
            whenPainted { [weak self] in
                guard let self, pending > 0 else { return }
                pending -= 1
                // A page that drew while asked counts here; the caller goes on itself.
                if pending == 0, !asking { end(then) }
            }
        }
        asking = false
        guard pending > 0 else { return false }
        timer.schedule(after: Self.deadline) { @MainActor [weak self] in
            guard let self, pending > 0 else { return }
            pending = 0
            end(then)
        }
        return true
    }

    private func end(_ then: @MainActor () -> Void) {
        timer.cancel()
        then()
    }

    /// The chat pages among `views` that are in a window, not hidden and not drawn yet: what the person sees load.
    /// A New Tab page draws no chat.
    public static func loading(_ views: some Sequence<AgentPaneView>) -> [WhenPainted] {
        views.filter { $0.model.newTab == nil && !$0.model.hasPainted && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            .map { view in { view.model.whenPainted($0) } }
    }
}
