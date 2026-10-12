import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import os

/// Lets hidden agent chat pages go (cx-x15rz). Each chat tab's page is a web view with its own
/// web content process (about 75 MB), and before this it stayed until the tab closed. A chat
/// hidden past the browser pages' threshold (`browser.hibernation` and memory pressure, as
/// `HibernationPlanner` sets it) lets its page go; its tab keeps its session, so showing it again
/// builds the page on the same chat (``AgentTabStore/view(for:)``), which acpmux replays with its
/// draft. Its last frame is drawn under the pane until the new page paints.
///
/// A page stays when its tab is pinned (unless the setting includes pinned tabs), its agent
/// works or waits on the person, it is a New Tab page or another machine's chat, or a shell
/// command ran in it (closing the page ends the command or drops its output). A page waits at
/// least ``minimumHidden`` even under critical pressure, so the composer's last keystrokes reach
/// acpmux. Events only, no polling: a page hides or shows (`TabContentCache`'s presentation
/// changes), the setting or the pressure changes, and one deadline for the next page to come due.
@MainActor
final class AgentPageHibernation {
    static let minimumHidden: Double = 10

    /// The agent tab store once the App made it (no agent tab yet: nothing to release).
    private let store: () -> AgentTabStore?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    private(set) var setting: BrowserHibernationSetting = .fallback
    private(set) var pressure: MemoryPressureLevel = .normal
    /// When each hidden page was last visible.
    private var hiddenAt: [String: ContinuousClock.Instant] = [:]
    private var shown: Set<String> = []
    private var releasing: Set<String> = []
    private let deadline = DemandTimer(owner: "AgentPageHibernation")
    /// The tab's agent state (the store record); injected by the App.
    var agentState: (String) -> AgentState? = { _ in nil }
    var isPinned: (String) -> Bool = { _ in false }
    /// The pane still hosting tab `key`'s page lets it go (it shows the tab again on demand).
    var displace: (String) -> Void = { _ in }
    /// The clock (tests set it).
    var now: () -> ContinuousClock.Instant = { .now }
    private(set) var releasedCount = 0

    init(tabs: @escaping () -> AgentTabStore?) {
        store = tabs
    }

    /// Wired to the App: never makes the agent tab store (that starts acpmux), follows the panes'
    /// presentation changes, and lets the pane holding a released page go.
    convenience init(services: AppServices) {
        self.init(tabs: { [weak services] in services?.madeAgentTabs })
        isPinned = { [weak services] key in services?.locateTab(key)?.0.pinned ?? false }
        agentState = { [weak services] key in services?.locateTab(key)?.0.agent?.state }
        displace = { [weak services] key in services?.cache.presenter(of: key)?.surfaceWasDisplaced(key) }
        let cache = services.cache
        cache.presentationChanges.subscribe("agent-page-hibernation") { [weak self, weak cache] in
            guard let cache else { return }
            self?.sync { cache.isRendering($0) }
        }
    }

    func update(setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) {
        guard setting != self.setting || pressure != self.pressure else { return }
        (self.setting, self.pressure) = (setting, pressure)
        replan()
    }

    /// Compares every page with whether its tab draws now, and reports the ones that changed.
    func sync(_ isRendering: (String) -> Bool) {
        guard let tabs = store() else { return }
        for (key, view) in tabs.views {
            let visible = isRendering(key) || Self.isOnScreen(view)
            if visible != shown.contains(key) { pageVisibility(key, visible: visible) }
        }
    }

    /// Tab `key`'s page started or stopped drawing.
    func pageVisibility(_ key: String, visible: Bool) {
        guard let tabs = store() else { return }
        if visible {
            shown.insert(key)
            hiddenAt[key] = nil
            tabs.launchImages.drop(key)
        } else if tabs.existingView(key) != nil {
            shown.remove(key)
            hiddenAt[key] = now()
            replan()
        }
    }

    func forget(_ key: String) {
        shown.remove(key)
        hiddenAt[key] = nil
        store()?.launchImages.drop(key)
    }

    /// Releases every page that is due and arms one deadline for the next.
    func replan() {
        guard let tabs = store() else { return }
        hiddenAt = hiddenAt.filter { tabs.existingView($0.key) != nil }
        shown = shown.filter { tabs.existingView($0) != nil }
        guard let threshold = HibernationPlanner.threshold(setting, pressure: pressure).map({ max($0, Self.minimumHidden) }) else {
            deadline.cancel()
            return
        }
        let current = now()
        var next: Double?
        for (key, at) in hiddenAt where !releasing.contains(key) && keepsPage(key) == nil {
            let remaining = threshold - (current - at).seconds
            if remaining <= 0 {
                _ = key // red: a due page stays, as before (cx-x15rz)
            } else {
                next = min(next ?? remaining, remaining)
            }
        }
        if let next {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
    }

    /// Why tab `key`'s hidden page stays, or nil when it can go.
    func keepsPage(_ key: String) -> HibernationPlanner.Exemption? {
        if !setting.isEnabled { return .disabled }
        guard let tabs = store(), Self.canRelease(key, in: tabs) else { return .unsupported }
        if isPinned(key), !setting.includesPinnedTabs { return .pinned }
        if let state = agentState(key), state == .working || state == .blocked { return .agentBusy }
        return nil
    }

    /// A chat of this Mac's acpmux with a session, off screen, not a New Tab page, and no shell
    /// command run in it.
    private static func canRelease(_ key: String, in tabs: AgentTabStore) -> Bool {
        let key = tabs.resolve(key)
        guard let view = tabs.views[key], !isOnScreen(view), view.model.newTab == nil, !view.model.shell.hasRuns,
              tabs.newTabPages[key] == nil, let (record, _) = tabs.lookup(key),
              AgentPaneHostKind(record, localHost: tabs.localHost, chiefHost: tabs.chiefHost) == .local,
              tabs.daemonForTab(key)?.isLocal != false else { return false }
        return (tabs.sessions[key] ?? view.model.sessionId ?? record.session) != nil
            && tabs.remoteSeeds[key] == nil && tabs.remoteCreations[key] == nil && tabs.remoteStarts[key] == nil
    }

    private static func isOnScreen(_ view: AgentPaneView) -> Bool {
        view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    /// Keeps the page's frame, then lets the page go if it is still the same hidden page.
    private func release(_ key: String) {
        guard let tabs = store(), let view = tabs.existingView(key), releasing.insert(key).inserted else { return }
        Task { @MainActor [weak self] in
            let frame = await Self.frame(view)
            guard let self else { return }
            releasing.remove(key)
            guard hiddenAt[key] != nil, tabs.existingView(key) === view, keepsPage(key) == nil else { return }
            if let frame { await tabs.launchImages.hold(key, frame.image, size: frame.size) }
            guard hiddenAt[key] != nil, tabs.existingView(key) === view else {
                tabs.launchImages.drop(key)
                return
            }
            displace(key)
            // The tab keeps its session and every other state: the next show builds the page again.
            let stored = tabs.resolve(key)
            if let session = view.model.sessionId { tabs.sessions[stored] = session }
            tabs.views[stored] = nil
            tabs.retirer.retire(view)
            tabs.stopCustomizationWhenUnused()
            hiddenAt[key] = nil
            releasedCount += 1
            logger.info("released agent page \(key, privacy: .public)")
        }
    }

    /// The page as last drawn; nil when it does not answer in time (it then shows its loading
    /// state when it comes back).
    private static func frame(_ view: AgentPaneView) async -> (image: CGImage, size: NSSize)? {
        let frame = try? await ControlDeadline.shared.run(method: "hibernation.agentSnapshot", deadline: .now + .seconds(2)) { @MainActor in
            await view.pageImage().flatMap { image in image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, image.size) } }
        }
        return frame.flatMap { $0 }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
