public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// Owns the Chief pet: its panel, shown while it is turned on (made on first
/// show and kept, with its spot, while hidden), and the notice bubble over it
/// (`ChiefPetFeed`). A finished notice leaves on its own after
/// `doneSeconds`; one that waits for the user stays until its tab is read.
/// The notices are a toast, not a sticky card: a new one shows for `toastSeconds` and then folds
/// away (the badge keeps counting what waits), and they show over cmux only: over another app
/// only the pet and its badge do, and a desktop banner is the system's to show (Leo 2026-10-20:
/// a card floated over Chrome with the page's text bleeding through it). The rail's chevron
/// unfolds them anywhere.
/// The rail's chevron folds and unfolds the notices; a click on the pet, the rail's compose or
/// Message the Chief opens the reply box (`ChiefPetController+Reply`).
@MainActor
public final class ChiefPetController {
    /// How long a finished notice stays up.
    static let doneSeconds: Double = 8
    /// How long a new notice's card stays up before it folds into the badge.
    static let toastSeconds: Double = 8

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
    /// Folds the card away `toastSeconds` after the newest arrival.
    private let toast: DemandTimer
    /// A new notice's card is up (until `toast` fires); the chevron's `expanded` shows them regardless.
    private(set) var presenting = false
    /// Whether cmux is the active app: the card shows over cmux only.
    private let appIsActive: @MainActor () -> Bool
    /// The app-activation observers' tokens, kept for the controller's life.
    private var activationObservers: [MainActorObservation] = []
    private var watch: Task<Void, Never>?
    /// `home.chiefPetEnabled` as last followed: off, arrivals are dropped.
    public private(set) var isOn = false
    private(set) var mascot = ChiefPetMascot.initial
    /// The notices unfolded into a column (the rail's chevron); folded, a deck.
    private(set) var expanded = false
    /// Message the Chief ran while `home.chiefPetEnabled` was off: the pet shows for this message only
    /// and goes when its reply box closes; the setting turning on keeps it.
    var transient = false

    /// `appIsActive`: whether cmux is the active app (the App passes `NSApp.isActive`; tests pin one).
    /// `notifications`: where AppKit posts the app's activation changes; tests give their own.
    public init(makePanel: @escaping () -> ChiefPetPanel,
         actions: ChiefPetActions,
         clock: any Clock<Duration> = ContinuousClock(),
         appIsActive: @escaping @MainActor () -> Bool = { true },
         notifications: NotificationCenter = .default) {
        self.makePanel = makePanel
        self.actions = actions
        self.clock = clock
        self.appIsActive = appIsActive
        toast = DemandTimer(owner: "chiefPet.toast", clock: clock)
        // Switching to another app takes the card down at once; coming back shows it if its time is not up.
        activationObservers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map {
            MainActorObservation($0, center: notifications) { [weak self] in
                self?.render(animated: false)
            }
        }
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
            transient = false
            panelOnce().present()
            render(animated: false)
        } else {
            // Turned off, it forgets what it showed: a later show starts from new arrivals.
            feed.clear()
            expiries.values.forEach { $0.cancel() }
            expiries.removeAll()
            toast.cancel()
            presenting = false
            // A message summoned with the setting off (or turning off) keeps its box until it closes.
            if transient, replyPanel?.isVisible == true { return render(animated: false) }
            transient = false
            closeReply()
            render(animated: false)
            panel?.dismiss()
        }
    }

    /// Message the Chief (`home.messageChiefPet`): the pet with its reply box open, at once. `petOn` is
    /// `home.chiefPetEnabled` as the action read it; off, the pet shows for this message only and goes
    /// again when the box closes, so the setting stays as the person left it. An open box stays open.
    public func summon(petOn: Bool) {
        if !petOn || !isOn { transient = true }
        let panel = panelOnce()
        // On but ordered out (the app hidden): it comes back now, not on some later sync.
        if !panel.isVisible { panel.present() }
        openReply()
    }

    /// An agent event that alerts here (the notification service's arrival).
    public func arrive(_ notice: ChiefPetNotice) {
        guard isOn else { return }
        let change = feed.arrive(notice)
        // A finished notice that shows (newly, or as the newer id of the same content) leaves on its own.
        if !notice.kind.waits, feed.notices.contains(where: { $0.id == notice.id }) { scheduleExpiry(notice.id) }
        // Only a new front notice puts the card up again: the same content posted again (an agent's
        // next tool call) does not keep it up.
        if change == .arrived { present() }
        render(animated: change == .arrived)
    }

    /// Puts the card up for `toastSeconds`, then folds it into the badge.
    private func present() {
        presenting = true
        toast.schedule(after: .seconds(Self.toastSeconds)) { @MainActor [weak self] in
            guard let self else { return }
            self.presenting = false
            self.render(animated: false)
        }
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
        // While the reply box is up, it sits where the notices do. Unfolded by the chevron they show
        // anywhere; otherwise a new notice's card shows over cmux only, until its time is up.
        guard let panel, isOn, replyPanel?.isVisible != true, !feed.notices.isEmpty,
              expanded || (presenting && appIsActive()) else {
            hideBubble()
            return
        }
        let bubble = bubbleOnce()
        let drew = bubble.bubble.show(feed.notices, expanded: expanded)
        let height = ChiefPetBubblePanel.height(count: feed.notices.count, expanded: expanded)
        // With no screen (a display being reconfigured) it still takes its size, over the pet.
        let visible = panel.visibleFrame() ?? ChiefPetPanel.screenUnderPointer()?.visibleFrame ?? panel.frame.insetBy(dx: -4000, dy: -4000)
        bubble.setFrame(ChiefPetBubblePanel.frame(height: height, over: panel.frame, in: visible), display: drew)
        guard !bubble.isVisible else { return }
        bubble.alphaValue = animated && drew ? 0 : 1
        panel.addChildWindow(bubble, ordered: .above)
        bubble.orderFrontRegardless()
        if bubble.alphaValue == 0 {
            Motion.home.animateTimed(.fadeIn, in: bubble.contentView) { bubble.animator().alphaValue = 1 }
        }
    }

    /// Places the shown bubble and reply box toward the quadrant with room around the pet's frame now.
    func followPet() {
        guard let panel, let visible = panel.visibleFrame() ?? ChiefPetPanel.screenUnderPointer()?.visibleFrame else { return }
        if let bubble, bubble.isVisible {
            let height = ChiefPetBubblePanel.height(count: feed.notices.count, expanded: expanded)
            let frame = ChiefPetBubblePanel.frame(height: height, over: panel.frame, in: visible)
            if frame != bubble.frame { bubble.setFrame(frame, display: false) }
        }
        placeReply()
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
        // The right-click menu: the settings close the reply box first, so they come up alone.
        made.onSettings = { [weak self] in
            self?.closeReply()
            self?.actions.openSettings()
        }
        made.onHide = { [weak self] in self?.actions.hide() }
        made.hideAllowed = { [weak self] in self?.actions.canHide() ?? false }
        // With no notices the chevron opens the Chief.
        made.onExpand = { [weak self] in
            guard let self else { return }
            guard !self.feed.notices.isEmpty else { return self.actions.open(.chief) }
            self.expanded.toggle()
            self.panel?.setExpanded(self.expanded)
            self.render(animated: false)
        }
        // A drag moves the bubble with the pet (a child window), and each step turns it (and the
        // reply box) toward the quadrant with room, so the drop moves nothing. Only frames
        // change: nothing is redrawn and nothing fades in again.
        made.pet.onDragMoved = { [weak self] in self?.followPet() }
        made.pet.onDragEnded = { [weak self, weak made] in
            made?.saveOrigin()
            self?.render(animated: false)
            self?.placeReply()
        }
        made.onKeptOnScreen = { [weak self] in
            self?.render(animated: false)
            self?.placeReply()
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
