public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// Owns the Chief pet: its panel, shown while it is turned on (made on first
/// show and kept, with its spot, while hidden), and the notice bubble over it
/// (`ChiefPetFeed`). A finished notice leaves on its own after
/// `doneSeconds`; one that waits for the user stays until its tab is read.
/// The rail's chevron folds and unfolds the notices; a click on the pet or the rail's compose
/// opens the reply box (`ChiefPetController+Reply`).
@MainActor
public final class ChiefPetController {
    /// How long a finished notice stays up.
    static let doneSeconds: Double = 8

    private let makePanel: () -> ChiefPetPanel
    /// Opening and sending, the App's (a click on a notice opens its tab).
    let actions: ChiefPetActions
    private let clock: any Clock<Duration>
    private(set) var panel: ChiefPetPanel?
    private(set) var bubble: ChiefPetBubblePanel?
    private(set) var feed = ChiefPetFeed()
    /// The reply box, made on the first click on the pet.
    var replyPanel: ChiefPetReplyPanel?
    /// A send in flight: Return again does nothing until it is answered.
    var sending = false
    /// Ordering the reply box out takes its keys, which would close it again.
    var closingReply = false
    /// Finished notices' leave timers, by notification id (one-shot `DemandTimer`s).
    private var expiries: [UInt64: DemandTimer] = [:]
    private var watch: Task<Void, Never>?
    /// `home.chiefPetEnabled` as last followed: off, arrivals are dropped.
    public private(set) var isOn = false
    private(set) var mascot = ChiefPetMascot.initial
    /// The notices unfolded into a column (the rail's chevron); folded, a deck.
    private(set) var expanded = false

    public init(makePanel: @escaping () -> ChiefPetPanel,
         actions: ChiefPetActions,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.makePanel = makePanel
        self.actions = actions
        self.clock = clock
    }

    var isShown: Bool { panel?.isVisible == true }


    /// Follows `enabled` (`home.chiefPetEnabled`) and `mascot` (`home.chiefPetMascot`, a
    /// `ChiefPetMascot` id), read under observation: shows the pet when it turns on, hides it when
    /// it turns off, and draws the chosen character.
    public func start(enabled: @escaping @MainActor @Sendable () -> Bool,
                      mascot: @escaping @MainActor @Sendable () -> String = { ChiefPetMascot.initial.rawValue }) {
        // task-owner: lives as long as the app services; event-driven (Observation)
        watch = Task { [weak self] in
            for await (on, id) in ObservationStream({ (enabled(), mascot()) }) {
                self?.setMascot(ChiefPetMascot(rawValue: id) ?? .initial)
                self?.sync(on)
            }
        }
    }

    /// Draws `mascot` from now on (the panel keeps it while hidden).
    func setMascot(_ mascot: ChiefPetMascot) {
        guard mascot != self.mascot else { return }
        self.mascot = mascot
        panel?.pet.image = mascot.image
    }

    func sync(_ on: Bool) {
        isOn = on
        if on {
            panelOnce().present()
            render(animated: false)
        } else {
            // Turned off, it forgets what it showed: a later show starts from new arrivals.
            closeReply()
            feed.clear()
            expiries.values.forEach { $0.cancel() }
            expiries.removeAll()
            render(animated: false)
            panel?.dismiss()
        }
    }

    /// An agent event that alerts here (the notification service's arrival).
    public func arrive(_ notice: ChiefPetNotice) {
        guard isOn else { return }
        let change = feed.arrive(notice)
        // A finished notice that shows (newly, or as the newer id of the same content) leaves on its own.
        if !notice.kind.waits, feed.notices.contains(where: { $0.id == notice.id }) { scheduleExpiry(notice.id) }
        render(animated: change == .arrived)
    }

    /// Keeps only the notices whose tab `isUnread` says still holds one (a tab read anywhere else).
    public func keepNotices(_ isUnread: (_ tab: String) -> Bool) {
        let gone = Set(feed.notices.map(\.tab).filter { !isUnread($0) })
        guard !gone.isEmpty else { return }
        for tab in gone { feed.read(tab: tab) }
        render(animated: false)
    }

    /// `tab` was read (opened, answered, dismissed): its notice goes.
    public func read(tab: String) {
        guard feed.notices.contains(where: { $0.tab == tab }) else { return }
        feed.read(tab: tab)
        render(animated: false)
    }

    private func scheduleExpiry(_ id: UInt64) {
        let timer = DemandTimer(owner: "chiefPet.notice", clock: clock)
        expiries[id] = timer
        timer.schedule(after: .seconds(Self.doneSeconds)) { @MainActor [weak self] in
            guard let self else { return }
            self.expiries[id] = nil
            self.feed.expire(id: id)
            self.render(animated: false)
        }
    }

    /// Draws the feed: the badge, and the bubble while there is a notice.
    /// `animated`: a new front notice fades the bubble in once; nothing else moves.
    func render(animated: Bool) {
        panel?.pet.badge = feed.attention
        replyPanel?.show(targets: ChiefPetReply.targets(feed))
        if feed.notices.isEmpty, expanded {
            expanded = false
            panel?.setExpanded(false)
        }
        // While the reply box is up, it sits where the notices do.
        guard let panel, isOn, replyPanel?.isVisible != true, !feed.notices.isEmpty else {
            hideBubble()
            return
        }
        let bubble = bubbleOnce()
        let drew = bubble.bubble.show(feed.notices, expanded: expanded)
        let height = ChiefPetBubblePanel.height(count: feed.notices.count, expanded: expanded)
        // With no screen (a display being reconfigured) it still takes its size, over the pet.
        let visible = panel.screen?.visibleFrame ?? ChiefPetPanel.screenUnderPointer()?.visibleFrame ?? panel.frame.insetBy(dx: -4000, dy: -4000)
        bubble.setFrame(ChiefPetBubblePanel.frame(height: height, over: panel.frame, in: visible), display: drew)
        guard !bubble.isVisible else { return }
        bubble.alphaValue = animated && drew ? 0 : 1
        panel.addChildWindow(bubble, ordered: .above)
        bubble.orderFrontRegardless()
        if bubble.alphaValue == 0 {
            Motion.animateTimed(.fadeIn, in: bubble.contentView) { bubble.animator().alphaValue = 1 }
        }
    }

    func hideBubble() {
        guard let bubble, bubble.isVisible else { return }
        bubble.parent?.removeChildWindow(bubble)
        bubble.orderOut(nil)
    }

    private func panelOnce() -> ChiefPetPanel {
        if let panel { return panel }
        let made = makePanel()
        if mascot != .initial { made.pet.image = mascot.image }
        made.onClick = { [weak self] in self?.toggleReply() }
        // With no notices the chevron opens the Chief.
        made.onExpand = { [weak self] in
            guard let self else { return }
            guard !self.feed.notices.isEmpty else { return self.actions.open(.chief) }
            self.expanded.toggle()
            self.panel?.setExpanded(self.expanded)
            self.render(animated: false)
        }
        // A drag moves the bubble with the pet (a child window); at its end the bubble turns
        // to the side with room (above, or below near the screen's top).
        made.pet.onDragEnded = { [weak self, weak made] in
            made?.saveOrigin()
            self?.render(animated: false)
        }
        panel = made
        return made
    }

    private func bubbleOnce() -> ChiefPetBubblePanel {
        if let bubble { return bubble }
        let made = ChiefPetBubblePanel()
        made.onOpen = { [weak self] index in
            guard let self, self.feed.notices.indices.contains(index) else { return }
            self.actions.open(.notice(self.feed.notices[index]))
        }
        bubble = made
        return made
    }
}
