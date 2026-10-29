import AppKit
import CmuxNextDesign
public import CmuxNextWakeups

extension SidebarView {
    /// Shows Energy Saver's leaf while the policy of `deadlines`' scheduler (`MainWorkScheduler.energy`)
    /// is in the saver. `deadlines` is the app's one deadline scheduler: the card's close
    /// grace runs on it. `batteryPercent` reads the battery's charge for the low-battery card line (the
    /// App's one energy monitor); the card reads it when it opens, nothing polls it. The App calls this
    /// once per sidebar.
    public func followEnergy(_ deadlines: MainDeadlineScheduler, batteryPercent: @escaping () -> Int? = { nil }) {
        energyIndicator.batteryPercent = batteryPercent
        energyIndicator.follow(deadlines)
    }

    /// The Energy Saver card's "Turn Off for Now" was pressed: the App runs `energy.saver.turnOffForNow`.
    /// Nil leaves the button doing nothing.
    public var onTurnOffEnergySaver: (() -> Void)? {
        get { energyIndicator.onTurnOffForNow }
        set { energyIndicator.onTurnOffForNow = newValue }
    }

    /// Adds the leaf on the footer's line (init): its card opens in the list's hover card window, and
    /// showing or hiding it lays the footer out again.
    func installEnergyIndicator() {
        energyIndicator.hoverCards = { [weak self] in self?.list.hoverCards }
        energyIndicator.onShownChange = { [weak self] in self?.needsLayout = true }
        addSubview(energyIndicator)
    }
}

/// Energy Saver's leaf in the sidebar footer: a leaf glyph at the trailing end of
/// the footer's first line while the saver is on, and nothing at all while it is off. Pointing at it
/// or clicking it shows a card in the app's one hover card window with why the saver is on and
/// "Turn Off for Now". Full Keyboard Access reaches the leaf (Tab, then Space) and VoiceOver presses
/// it; either opens or closes the card. The keyboard's path to "Turn Off for Now" itself is the
/// palette's `energy.saver.turnOffForNow`.
///
/// Chrome's Energy Saver shows the same thing: a leaf in the toolbar while battery saver is active,
/// whose bubble names the saver and offers "Turn off for now"
/// (chrome/browser/ui/views/performance_controls/battery_saver_button.cc,
/// battery_saver_bubble_view.cc; `BatterySaverModeManager::SetTemporaryBatterySaverDisabledForSession`).
///
/// It observes only the app's ``EnergyPolicySource`` (`MainWorkScheduler.energy`): no setting, no
/// power API, no timer polls it. A policy change shows or hides the leaf through `Motion.indicators`,
/// so Reduce Motion and the animation switches apply. That fade moves the leaf button's opacity; the
/// indicator's own opacity belongs to the sidebar's chrome reveal (minimal mode fades it with the
/// footer), so the two fades never write the same value. The `energySaver` feature (default off) keeps
/// the policy out of the saver, so the leaf never shows while it is off.
@MainActor
final class SidebarEnergyIndicator: NSView {
    /// The leaf; a click opens the card, a key or VoiceOver press opens or closes it.
    let button = SidebarIconButton(symbol: "leaf", pointSize: { Metrics.iconSize }, label: Strings.energySaver)
    /// The card's content, reused for every show.
    let card = SidebarEnergyCardView()
    /// The coordinator of the app's one hover card window (the App injects it into the sidebar).
    var hoverCards: () -> HoverCardCoordinator? = { nil }
    /// "Turn Off for Now" was pressed: the App runs `energy.saver.turnOffForNow`.
    var onTurnOffForNow: (() -> Void)?
    /// The battery's charge in percent, read when the card opens or its content changes (the App
    /// reads its one energy monitor); nil names no number.
    var batteryPercent: () -> Int? = { nil }
    /// The leaf appeared or went away: the footer makes room for it or takes the room back.
    var onShownChange: (() -> Void)?

    /// Why the saver is on; nil while it is off, and then the leaf does not show.
    private(set) var reason: EnergyPolicy.Reason?
    /// The saver is on and the Mac runs on battery: plugging it in also ends "Turn Off for Now".
    private(set) var onBattery = false
    /// The leaf takes room in the footer.
    var isShown: Bool { reason != nil }

    /// How long the card stays after the pointer left the leaf or the card, so it can cross the gap
    /// between them (the pull request card's grace).
    static let closeGrace: Duration = .milliseconds(250)

    /// This leaf's card: one per sidebar, so two windows' leaves never take each other's card.
    private(set) lazy var cardID = HoverTargetID("sidebar:energy-saver:\(UInt(bitPattern: ObjectIdentifier(self).hashValue))")
    private var source: EnergyPolicySource?
    private var observation: EnergyPolicyObservation?
    /// The grace before the card closes; armed by a pointer exit only.
    private var closer: MainDeadline?
    /// Bumped by each show or hide, so an old fade's completion does not hide a leaf shown again.
    private var fadeGeneration = 0
    /// The events of a click: the pointer that clicks has already opened the card by entering the leaf.
    private static let clicks: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp]

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        button.alphaValue = 0
        // The card says what the leaf means; a tooltip on top of it would repeat it.
        button.showsLabelToolTip = false
        // Tab reaches the leaf and Space presses it, with the theme's focus ring (the card x's rule).
        button.takesKeyFocus = true
        button.onPress = { [weak self] in self?.pressed() }
        button.setAccessibilityIdentifier("cmux.sidebar.energySaver")
        addSubview(button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        card.turnOff.onPress = { [weak self] in self?.turnOffForNow() }
        card.onPointerEnter = { [weak self] in self?.closer?.cancel() }
        card.onPointerExit = { [weak self] in self?.scheduleClose() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Follows the Energy Saver policy of `deadlines`' scheduler (`MainWorkScheduler.energy`) from now on;
    /// the current one shows at once, without a fade. The card's close grace is a deadline on `deadlines`.
    func follow(_ deadlines: MainDeadlineScheduler) {
        let work = deadlines.work
        let source = work.energy
        self.source = source
        closer = MainDeadline(owner: "Sidebar.energyCard.close", workClass: .visible, scheduler: deadlines)
        observation = source.observe { [weak self, weak work] policy in
            // The source tells observers on its writer's thread: the policy driver's, the main actor.
            guard Thread.isMainThread else {
                // The posted task reads the source's latest policy, so posts never reorder what shows.
                work?.postFromAnyThread(.visible, owner: "Sidebar.energySaver") { [weak self] in self?.applyLatest() }
                return
            }
            // main-proof: guarded by Thread.isMainThread above
            MainActor.assumeIsolated { self?.apply(policy, animated: true) }
        }
        apply(source.policy, animated: false)
    }

    private func applyLatest() {
        guard let source else { return }
        apply(source.policy, animated: true)
    }

    /// Shows the leaf for `policy`'s saver reason, or hides it (and its card) when the saver is off.
    func apply(_ policy: EnergyPolicy, animated: Bool) {
        let reason = policy.isSaver ? policy.reason : nil
        let onBattery = reason != nil && policy.onBattery
        guard reason != self.reason || onBattery != self.onBattery else { return }
        let wasShown = isShown
        self.reason = reason
        self.onBattery = onBattery
        if reason != nil {
            configureCard()
            if isCardShown { hoverCards()?.refitOwned(cardID) }
        } else {
            closeCard()
        }
        if isShown != wasShown {
            fade(shown: isShown, animated: animated)
            onShownChange?()
        }
    }

    private func fade(shown: Bool, animated: Bool) {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        if shown { isHidden = false }
        guard animated else {
            button.alphaValue = shown ? 1 : 0
            isHidden = !shown
            return
        }
        Motion.indicators.animate(shown ? .fadeIn : .fadeOut, in: self, { button.animator().alphaValue = shown ? 1 : 0 },
                                  completion: { [weak self] in
                                      guard let self, !shown, self.fadeGeneration == generation else { return }
                                      self.isHidden = true
                                  })
    }

    override func layout() {
        super.layout()
        button.frame = bounds
    }

    // MARK: Card

    /// The card shows (and is not closing).
    var isCardShown: Bool { hoverCards()?.isShowingOwned(cardID) ?? false }

    /// Shows the card above the leaf. No-op while the saver is off or the leaf is not on screen.
    func showCard() {
        closer?.cancel()
        guard reason != nil, let window, !isHidden, !visibleRect.isEmpty, let cards = hoverCards() else { return }
        configureCard()
        let body = HoverCardBody(view: card, placement: .above, themeAnchor: self) { [weak card] in card?.applyColors() }
        cards.presentOwned(cardID, body: body, anchor: screenFrame(in: window), parent: window, interactive: true) { [weak self] in
            self?.closer?.cancel()
        }
        card.applyColors()
    }

    /// Closes the card (it fades out); no-op when it does not show.
    func closeCard() {
        closer?.cancel()
        hoverCards()?.endOwned(cardID)
    }

    private func configureCard() {
        guard let reason else { return }
        card.configure(reason: reason, batteryPercent: reason == .battery ? batteryPercent() : nil, onBattery: onBattery)
    }

    /// A click keeps the card the pointer opened when it entered the leaf (Chrome's battery saver
    /// button opens its bubble on a click); Space and VoiceOver's press open or close it.
    private func pressed() {
        if let type = NSApp?.currentEvent?.type, Self.clicks.contains(type) {
            showCard()
        } else if isCardShown {
            closeCard()
        } else {
            showCard()
        }
    }

    private func turnOffForNow() {
        closeCard()
        onTurnOffForNow?()
    }

    private func scheduleClose() {
        closer?.schedule(after: Self.closeGrace) { [weak self] in self?.closeUnlessPointed() }
    }

    private func closeUnlessPointed() {
        let pointer = NSEvent.mouseLocation
        if let frame = hoverCards()?.ownedCardFrame(cardID), frame.contains(pointer) { return }
        if let window, !isHidden, !visibleRect.isEmpty, screenFrame(in: window).contains(pointer) { return }
        closeCard()
    }

    private func screenFrame(in window: NSWindow) -> CGRect {
        window.convertToScreen(convert(bounds, to: nil))
    }

    // MARK: Pointer

    override func mouseEntered(with event: NSEvent) {
        showCard()
    }

    override func mouseExited(with event: NSEvent) {
        scheduleClose()
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension SidebarViewComponents {
    /// Proofs (the `energy-saver` capture scene): opens the leaf's card as a hover would; what shows.
    public func debugShowEnergyCard() -> [String: String] {
        // sync-layout: proofs: showCard reads the leaf's laid-out visibleRect and frame.
        layoutSubtreeIfNeeded()
        energyIndicator.showCard()
        return debugEnergyCardState()
    }

    /// Proofs: whether the leaf and its card show, the reason and the card's lines.
    public func debugEnergyCardState() -> [String: String] {
        ["shown": String(energyIndicator.isShown),
         "opaque": String(!energyIndicator.isHidden && energyIndicator.alphaValue >= 1 && energyIndicator.button.alphaValue >= 1),
         "card": String(energyIndicator.isCardShown),
         "reason": energyIndicator.reason?.rawValue ?? "-",
         "lines": energyIndicator.card.reportedLines.joined(separator: " | ")]
    }
}
#endif
