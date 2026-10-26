import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Energy Saver's leaf in the sidebar footer (p14-energy-026): a leaf glyph at the trailing end of
/// the footer's first line while the saver is on, and nothing at all while it is off. Pointing at it
/// (or pressing it, for the keyboard and VoiceOver) shows a card in the app's one hover card window
/// with why the saver is on and "Turn Off for Now".
///
/// Chrome's Energy Saver shows the same thing: a leaf in the toolbar while battery saver is active,
/// whose bubble names the saver and offers "Turn off for now"
/// (chrome/browser/ui/views/performance_controls/battery_saver_button.cc,
/// battery_saver_bubble_view.cc; `BatterySaverModeManager::SetTemporaryBatterySaverDisabledForSession`).
///
/// It observes only the app's ``EnergyPolicySource`` (`MainWorkScheduler.energy`): no setting, no
/// power API, no timer polls it. A policy change shows or hides the leaf through `Motion.indicators`,
/// so Reduce Motion and the animation switches apply. The `energySaver` feature (default off) keeps
/// the policy out of the saver, so the leaf never shows while it is off.
@MainActor
final class SidebarEnergyIndicator: NSView {
    /// The leaf; a press opens or closes the card.
    let button = SidebarIconButton(symbol: "leaf", pointSize: { Metrics.iconSize }, label: Strings.energySaver)
    /// The card's content, reused for every show.
    let card = SidebarEnergyCardView()
    /// The coordinator of the app's one hover card window (the App injects it into the sidebar).
    var hoverCards: () -> HoverCardCoordinator? = { nil }
    /// "Turn Off for Now" was pressed: the App runs `energy.saver.turnOffForNow` (p14-energy-025).
    var onTurnOffForNow: (() -> Void)?
    /// The leaf appeared or went away: the footer makes room for it or takes the room back.
    var onShownChange: (() -> Void)?

    /// Why the saver is on; nil while it is off, and then the leaf does not show.
    private(set) var reason: EnergyPolicy.Reason?
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
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        alphaValue = 0
        // The card says what the leaf means; a tooltip on top of it would repeat it.
        button.showsLabelToolTip = false
        button.onPress = { [weak self] in self?.toggleCard() }
        button.setAccessibilityIdentifier("cmux.sidebar.energySaver")
        addSubview(button)
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
        guard reason != self.reason else { return }
        let wasShown = isShown
        self.reason = reason
        if let reason {
            card.configure(reason: reason)
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
            alphaValue = shown ? 1 : 0
            isHidden = !shown
            return
        }
        Motion.indicators.animate(shown ? .fadeIn : .fadeOut, in: self, { animator().alphaValue = shown ? 1 : 0 },
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
        guard let reason, let window, !isHidden, !visibleRect.isEmpty, let cards = hoverCards() else { return }
        card.configure(reason: reason)
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

    private func toggleCard() {
        if isCardShown { closeCard() } else { showCard() }
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        showCard()
    }

    override func mouseExited(with event: NSEvent) {
        scheduleClose()
    }
}

/// The leaf's card: "Energy Saver is on", why, what it changes, and "Turn Off for Now".
@MainActor
final class SidebarEnergyCardView: NSView, HoverCardTextReporting {
    static let width: CGFloat = 260

    let turnOff = SidebarCardTextButton()
    var onPointerEnter: (() -> Void)?
    var onPointerExit: (() -> Void)?
    private let title = ChromeLabel(labelWithString: Strings.energySaverOn)
    private let reasonLabel = ChromeLabel(wrappingLabelWithString: "")
    private let effect = ChromeLabel(wrappingLabelWithString: Strings.energySaverEffect)
    private var tracking: NSTrackingArea?

    var reportedLines: [String] { [title.stringValue, reasonLabel.stringValue, effect.stringValue, turnOff.title] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Typography.bodyEmphasized
        reasonLabel.font = Typography.body
        effect.font = Typography.caption
        turnOff.configure(title: Strings.energySaverTurnOffForNow, help: Strings.energySaverTurnOffForNowHelp)
        let text = Self.width - 2 * Metrics.space3
        for label in [reasonLabel, effect] { label.preferredMaxLayoutWidth = text }
        let stack = NSStackView(views: [title, reasonLabel, effect, turnOff])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        stack.setCustomSpacing(Metrics.space2, after: effect)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = Metrics.space3
        turnOff.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            reasonLabel.widthAnchor.constraint(equalToConstant: text),
            effect.widthAnchor.constraint(equalToConstant: text),
            // The text button sits on the text's leading edge: its hover fill's inset hangs outside it.
            turnOff.widthAnchor.constraint(equalToConstant: turnOff.fittingWidth),
            turnOff.heightAnchor.constraint(equalToConstant: SidebarCardTextButton.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.energySaverOn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(reason: EnergyPolicy.Reason) {
        reasonLabel.stringValue = Strings.energySaverReason(reason)
    }

    func applyColors() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            reasonLabel.textColor = Palette.textSecondary
            effect.textColor = Palette.textTertiary
        }
        turnOff.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerEnter?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }
}

extension Strings {
    /// The leaf's VoiceOver label.
    static var energySaver: String { String(localized: "sidebar.energySaver", defaultValue: "Energy Saver", bundle: .module) }
    /// The card's title.
    static var energySaverOn: String { String(localized: "sidebar.energySaver.on", defaultValue: "Energy Saver is on", bundle: .module) }
    /// What the saver changes, and what it leaves alone.
    static var energySaverEffect: String {
        String(localized: "sidebar.energySaver.effect",
               defaultValue: "cmux draws fewer frames and wakes less often. Typing and scrolling are not slowed.", bundle: .module)
    }
    static var energySaverTurnOffForNow: String {
        String(localized: "sidebar.energySaver.turnOffForNow", defaultValue: "Turn Off for Now", bundle: .module)
    }
    static var energySaverTurnOffForNowHelp: String {
        String(localized: "sidebar.energySaver.turnOffForNow.help",
               defaultValue: "Keeps Energy Saver off until you plug in your Mac or change the Energy Saver setting.", bundle: .module)
    }
    /// Why the saver is on.
    static func energySaverReason(_ reason: EnergyPolicy.Reason) -> String {
        switch reason {
        case .lowPowerMode:
            String(localized: "sidebar.energySaver.reason.lowPowerMode", defaultValue: "Low Power Mode is on.", bundle: .module)
        case .battery:
            String(localized: "sidebar.energySaver.reason.battery", defaultValue: "The battery is low.", bundle: .module)
        case .thermal:
            String(localized: "sidebar.energySaver.reason.thermal", defaultValue: "Your Mac is hot and running on battery.", bundle: .module)
        case .setting:
            String(localized: "sidebar.energySaver.reason.setting", defaultValue: "Your Energy Saver setting turned it on.", bundle: .module)
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension SidebarViewComponents {
    /// Proofs (the `energy-saver` capture scene): opens the leaf's card as a hover would; what shows.
    public func debugShowEnergyCard() -> [String: String] {
        layoutSubtreeIfNeeded()
        energyIndicator.showCard()
        return debugEnergyCardState()
    }

    /// Proofs: whether the leaf and its card show, the reason and the card's lines.
    public func debugEnergyCardState() -> [String: String] {
        ["shown": String(energyIndicator.isShown),
         "opaque": String(!energyIndicator.isHidden && energyIndicator.alphaValue >= 1),
         "card": String(energyIndicator.isCardShown),
         "reason": energyIndicator.reason?.rawValue ?? "-",
         "lines": energyIndicator.card.reportedLines.joined(separator: " | ")]
    }
}
#endif
