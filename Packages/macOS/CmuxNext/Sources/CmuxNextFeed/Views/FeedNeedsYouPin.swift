public import AppKit
import CmuxNextCompat

/// A view that pins one section under its header (Chief Home's transcript): the pinned Needs you
/// section's host (``FeedNeedsYouPin``).
@MainActor
public protocol FeedPinnedSectionHost: AnyObject {
    var pinnedSection: NSView? { get }
    func setPinnedSection(_ view: NSView?)
    func pinnedSectionDidResize()
}

/// The pinned Needs you section over the Feed's own model (Leo, via his Chief: "a pinned Needs you
/// view in Chief Home, Feed and iPhone listing items waiting on Leo (PRs held for his trial like
/// #30817, sign-ins, approvals, consent cards)"). It is a view on ``FeedModel/needsYou`` (the
/// requests the Feed pins), never a second store; its answers are the Feed's (``FeedNeedsYouView``).
/// The App gives it what only the App can do: install the Feed's hooks, reveal a tab, show the Feed.
@MainActor
public struct FeedNeedsYouPin {
    public let model: FeedModel
    /// Once before the first section: the Feed's own hooks (a request's answers, its row's who and where).
    public var prepare: () -> Void
    /// Reveals the tab or chat `context` names; false when there is none.
    public var reveal: (FeedContext) -> Bool
    /// The Feed's own page.
    public var showFeed: () -> Void
    /// Whether the person turned the pinned section on (Settings > Notifications > Feed > Pin Needs You
    /// in Chief, `feed.needsYouInChief`, off by default), read inside the observation so it switches live.
    /// Leo 2026-11-03: "I just wanted to see permission things, period, not a pinned thing by default.
    /// Toggle-on, yes, but I haven't verified the looks of that yet".
    public var isEnabled: () -> Bool

    public init(model: FeedModel, isEnabled: @escaping () -> Bool, prepare: @escaping () -> Void,
                reveal: @escaping (FeedContext) -> Bool, showFeed: @escaping () -> Void) {
        self.model = model
        self.isEnabled = isEnabled
        self.prepare = prepare
        self.reveal = reveal
        self.showFeed = showFeed
    }

    /// A Chief's conversation shows the section while it is turned on and anything waits; any other
    /// conversation never, and nothing shows while it is off (the default).
    public static func shows(isChief: Bool, enabled: Bool, waiting: Int) -> Bool { isChief && enabled && waiting > 0 }

    /// The section, wired to open what a click names.
    public func makeSection() -> FeedNeedsYouView {
        prepare()
        let section = FeedNeedsYouView(model: model)
        section.onOpen = { item in open(item) }
        section.onShowAll = { showFeed() }
        return section
    }

    /// A click on a request opens its source: its link (a pull request, a sign-in page) through the
    /// Feed's open; else the tab or chat that asked; else the Feed with it selected.
    public func open(_ item: FeedItem) {
        if item.context.url != nil { return model.open(item.id) }
        model.select(item.id)
        if !reveal(item.context) { showFeed() }
    }

    /// While a Chief's conversation shows, one observation of whether the section is on and the Feed has open requests puts the
    /// section under `host`'s header or takes it away; the section observes its own rows. No polling, no
    /// timer: it wakes only on a Feed change. The caller cancels the task when the conversation changes.
    public func watch(host: FeedPinnedSectionHost) -> Task<Void, Never> {
        let model = model, isEnabled = isEnabled, pin = self
        // task-owner: the caller's (HomeHostView.needsYouWatch), cancelled on the next change and in its deinit; event-driven (Observation)
        return Task { [weak host] in
            for await shows in ObservationStream({
                // Off reads no Feed state, so the Feed's changes never wake it.
                isEnabled() && FeedNeedsYouPin.shows(isChief: true, enabled: true, waiting: model.needsYou.count)
            }) {
                guard let host else { return }
                if !shows {
                    host.setPinnedSection(nil)
                } else if host.pinnedSection == nil {
                    let section = pin.makeSection()
                    section.onHeightChange = { [weak host] in host?.pinnedSectionDidResize() }
                    host.setPinnedSection(section)
                }
            }
        }
    }
}
