package import CmuxNextHibernation
package import CmuxNextPages

/// Who decides for an agent tab's page in the page lifecycle: the app's agent page
/// hibernation, which knows the tab's turn, pin, draft and machine, and lets the page go at its discard.
@MainActor
package protocol AgentPageLifecycleOwner: AnyObject {
    /// Encodes the page's hide-time picture (``PageWebView`` keeps it encoded).
    var snapshotEncoder: PageSnapshotEncoder { get }
    /// Why tab `key`'s page `pane` stays, with the reasons `page` reports itself (its load, its focus).
    func keepReasons(_ key: String, pane: AgentPaneView, page: PageWebViewLifecycle) -> Set<PageLifecyclePlanner.KeepReason>
    /// Tab `key`'s page `pane` hid, still running and in its window, after it began its hide picture.
    func pageDidHide(_ key: String, pane: AgentPaneView)
    /// Tab `key`'s page shows again running.
    func pageDidShow(_ key: String)
    /// Tab `key`'s hidden page froze: it answers nothing until it thaws.
    func pageDidFreeze(_ key: String)
    /// Tab `key`'s hidden page runs again (a reason that blocks a freeze began, or it shows).
    func pageDidThaw(_ key: String)
    /// The planner discards tab `key`'s hidden page `pane`: the owner lets the whole page go, asking it nothing.
    func discard(_ key: String, pane: AgentPaneView)
}

/// An agent tab's page (a chat or the New Tab page) as the page lifecycle drives it. Its ``PageWebView``
/// freezes, thaws and keeps its hide picture as every cmux page does (``PageWebViewLifecycle``); the tab's
/// keep reasons and its discard are its ``AgentPageLifecycleOwner``'s. The page view is the lifecycle's
/// object, so its own load and keep reasons (``PageLoadState``, ``PageKeepReasons``) reach it under the tab.
///
/// ```swift
/// lifecycle.pageOfTab = { key in tabs.existingView(key).map { AgentPageLifecycleTarget(key: key, pane: $0, owner: owner) } }
/// ```
package struct AgentPageLifecycleTarget: PageLifecycleTarget {
    package let key: String
    private weak var pane: AgentPaneView?
    private weak var owner: (any AgentPageLifecycleOwner)?
    private let page: PageWebViewLifecycle

    /// - Parameters:
    ///   - key: The agent tab.
    ///   - pane: Its live page.
    ///   - owner: Decides its keep reasons and performs its discard.
    package init(key: String, pane: AgentPaneView, owner: any AgentPageLifecycleOwner) {
        self.key = key
        self.pane = pane
        self.owner = owner
        page = PageWebViewLifecycle(pane.page, encoder: owner.snapshotEncoder)
    }

    package var object: AnyObject? { page.object }

    package var lifecycleGroup: String? { page.lifecycleGroup }

    package var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> {
        guard let pane, let owner else { return page.lifecycleKeepReasons }
        return owner.keepReasons(key, pane: pane, page: page)
    }

    package func reportsReasonChanges(to lifecycle: PageLifecycle) { page.reportsReasonChanges(to: lifecycle) }

    package func keepHideSnapshot() {
        page.keepHideSnapshot()
        if let pane { owner?.pageDidHide(key, pane: pane) }
    }

    package func dropHideSnapshot() {
        page.dropHideSnapshot()
        owner?.pageDidShow(key)
    }

    package func freeze() -> Bool {
        guard page.freeze() else { return false }
        pane?.pageDidFreeze()
        owner?.pageDidFreeze(key)
        return true
    }

    /// The page runs again first, then its transport sends what it kept (into the router's hold while
    /// the page is still hidden), then the owner hears it.
    package func thaw() {
        page.thaw()
        pane?.pageDidThaw()
        owner?.pageDidThaw(key)
    }

    package func discard() -> Bool {
        guard let pane, let owner else { return false }
        owner.discard(key, pane: pane)
        return true
    }

    package var holdsEnginePage: Bool { page.holdsEnginePage }
}
