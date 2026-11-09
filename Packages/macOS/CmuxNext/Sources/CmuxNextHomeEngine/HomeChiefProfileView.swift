public import AppKit
import CmuxNextDesign
import CmuxNextHome

/// The Chief's profile (Lawrence's reference, 2026-11-04, after Grok's bot panel): a close button at
/// the top right, the avatar and name centered, the tabs Details · Settings · Computer, then the tab.
///
/// Two places show it. The panel beside Home's chat, which the header's avatar and name pill open,
/// carries the Chief's whole settings card (``settings``): Details and Settings are its sections and
/// Computer adds the Computer Use picker of a Chief of this Mac, so every setting is in exactly one
/// tab. The expanded computer page (a tab beside Home, ``isExpanded``) has no card: Details says where
/// the Chief runs and links to Settings, and Computer shows the screen large.
///
/// Computer always shows, so the feature can be found: without a plan that pays for cmux Cloud it is
/// the upsell, for a Chief of this Mac it offers the move or a Cloud machine, and while the Chief has
/// none (never set up, or the one it had is gone) it offers one or says how to ask. Under a live screen the control bar says who drives and changes it.
@MainActor
public final class HomeChiefProfileView: NSView {
    /// Why the Computer tab has no screen; nil when it does.
    public enum Gate: Equatable, Sendable {
        case paywall, needsCloudChief, notSetUp
        /// A Chief of this Mac that uses one of the person's Cloud machines (its desktop opens on its own).
        case machine
    }

    /// The gate for a read: the plan first, since the upsell is the same wherever the Chief runs.
    public nonisolated static func gate(paid: Bool, cloudChief: Bool, hasComputer: Bool, machine: Bool = false) -> Gate? {
        guard paid else { return .paywall }
        guard cloudChief else { return machine ? .machine : .needsCloudChief }
        return hasComputer ? nil : .notSetUp
    }

    /// The panel's width beside the chat (the settings card's, which sets its rows).
    public static let panelWidth: CGFloat = HomeChiefSettingsView.width + 32
    static let columnWidth: CGFloat = 288
    /// The expanded page's note wraps at this width, however wide the screen it stands in for.
    static let expandedNoteWidth: CGFloat = 640
    /// The expanded page's height that is not the screen: the header (avatar, name, tabs), the
    /// control bar and the gaps, so the 16:10 screen fits the pane below it.
    static let expandedChrome: CGFloat = avatarTop + avatarSize + nameGap + 2 * tabsGap + 140
    static let avatarSize: CGFloat = 60
    static let avatarTop: CGFloat = 64
    static let nameGap: CGFloat = 12
    static let tabsGap: CGFloat = 20

    public let computer = HomeChiefComputerSection()
    /// The Chief's settings card (the panel); nil on the expanded page.
    public let settings: HomeChiefSettingsView?
    /// The page shows the computer large (a tab beside Home, no card), not the panel.
    public var isExpanded: Bool { settings == nil }
    /// The Chief's name, read when the page opens and at each status read.
    public var name: () -> String = { "" } { didSet { refresh() } }
    /// Whether the plan pays for cmux Cloud.
    public var paid: () -> Bool = { false } { didSet { refresh() } }
    /// Whether the Chief runs in the Cloud.
    public var cloudChief: () -> Bool = { false } { didSet { refresh() } }
    /// Where the Chief runs, for Details on the expanded page.
    public var place: () -> String = { "" } { didSet { refresh() } }
    /// The ✕.
    public var onClose: () -> Void = {}
    /// The tab on show changed: a pick, or the panel opened or closed (the chat's computer popup follows it).
    public var onTab: () -> Void = {}
    /// Upgrade, on the paywall.
    public var onUpgrade: () -> Void = {}
    /// Move to Cloud, for a Chief of this Mac.
    public var onMoveToCloud: () -> Void = {}
    /// Set Up Computer, for a Cloud Chief with none: asks the Cloud service to make it one (made in the
    /// background; the status says when it is there). Nil: the note asks the Chief to turn one on instead.
    public var onProvision: (@MainActor () async throws -> Void)? { didSet { refresh() } }
    /// The Set Up Computer ask in flight, or the reason the last one failed.
    var provisionAsk: ProvisionAsk = .idle
    enum ProvisionAsk: Equatable { case idle, asking, failed }
    /// All Chief Settings…, in the expanded page's Details.
    public var onSettings: () -> Void = {}
    /// Expand, on the screen: opens the expanded page (the panel only).
    public var onExpand: (() -> Void)? {
        didSet { computer.onExpand = onExpand }
    }
    /// Who drives the Chief's computer, and the person's input to it (``HomeChiefComputerControlBar``).
    public var control: HomeChiefComputerControlSource? {
        didSet { controlBar.source = control }
    }

    let tabs = HomeChiefSettingsTabs()
    let avatar: HomeChiefAvatarButton
    let nameLabel = ThemedLabel(labelWithString: "")
    /// The expanded page's Details (the panel's are the card's).
    let details = NSStackView()
    let placeLabel = ThemedLabel(labelWithString: "")
    let computerPane = NSStackView()
    /// The note and button that stand in for the screen.
    let gateBox = NSView()
    let gateLabel = ThemedLabel(wrappingLabelWithString: "")
    let gateButton = NSButton(title: "", target: nil, action: nil)
    let controlBar = HomeChiefComputerControlBar()
    let scroll = NSScrollView()
    let column = NSStackView()
    private(set) lazy var closeButton = HomeChiefCardCloseButton(label: HomeEngineStrings.closeCard, target: self, action: #selector(closeTab),
                                                                     size: HomeSidebarHeaderLayout.chatButtonSide)
    /// What the tab shows now.
    private(set) var shownGate: Gate?
    /// The person's inputs, sent one after another.
    let inputs = HomeChiefComputerInputQueue()
    /// The panel or page is on screen: the computer and the card's sections read.
    private(set) var isOpen = false
    /// The control bar keeps the computer it was given (the capture scene's fixture): the panel's
    /// ``HomeChiefProfilePanel/follow(agent:machine:make:)`` changes nothing.
    var pinsControl = false

    public init(settings: HomeChiefSettingsView? = nil) {
        self.settings = settings
        avatar = settings?.avatarButton ?? HomeChiefAvatarButton(size: Self.avatarSize)
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(settings == nil ? "cmux.home.chief.profile" : "cmux.home.chief.profile.panel")
        buildColumn()
        tabs.shown = settings == nil ? [.details, .computer] : HomeChiefProfileTab.allCases
        tabs.select(settings == nil ? .computer : .details)
        tabs.onPick = { [weak self] _ in
            self?.refresh()
            self?.onTab()
        }
        computer.onResize = { [weak self] in self?.refresh() }
        computer.onStatus = { [weak self] in self?.refresh() }
        controlBar.chief = { [weak self] in self?.name() ?? "" }
        controlBar.onChange = { [weak self] in self?.followControl() }
        controlBar.beforeGiveBack = { [weak self] in
            let inFlight = self?.inputs.drop()
            await inFlight?.value
        }
        inputs.failed = { [weak self] in
            guard let self, controlBar.personDrives else { return }
            controlBar.sendFailed()
        }
        settings?.onResize = { [weak self] in self?.needsLayout = true }
        settings?.onComputerShown = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated public override var isFlipped: Bool { true }

    /// The expanded page's widest column for the 16:10 screen to fit under the header (nil in the panel).
    var heightFit: NSLayoutConstraint?

    static func expandedWidth(height: CGFloat) -> CGFloat { max(0, (height - expandedChrome) * 16 / 10) }

    public override func layout() {
        if let heightFit {
            let width = Self.expandedWidth(height: bounds.height)
            if heightFit.constant != width { heightFit.constant = width }
        }
        super.layout()
    }

    /// The tab on show.
    public var selectedTab: HomeChiefProfileTab { tabs.selected }

    /// Shows `tab` (a gesture elsewhere asked for it: the pet's Chief Pet Settings… asks for Settings).
    public func select(_ tab: HomeChiefProfileTab) {
        guard tabs.shown.contains(tab) else { return }
        tabs.select(tab)
        refresh()
    }

    /// The avatar the Home header shows.
    public func setAvatar(picture: NSImage?, text: String?) {
        avatar.show(picture: picture, text: text)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followVisibility()
        applyGateFill()
    }

    /// A parked pane tab or a closed panel stays in the window, hidden: it reads nothing until it
    /// shows again.
    public override func viewDidHide() {
        super.viewDidHide()
        followVisibility()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        followVisibility()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGateFill()
    }

    /// Opens on screen (the computer and the card's sections read) and closes off it, keeping a name
    /// being edited.
    func followVisibility() {
        let open = window != nil && !isHiddenOrHasHiddenAncestor
        guard open != isOpen else { return }
        isOpen = open
        if open {
            computer.open()
            settings?.vault.open()
            settings?.connections.open()
            settings?.refresh()
        } else {
            computer.close()
            settings?.commitEditing()
            settings?.cardClosed()
            inputs.cancel()
        }
        refresh()
    }

    /// Shows the selected tab and, on Computer, the screen or why there is none.
    public func refresh() {
        nameLabel.stringValue = name()
        placeLabel.stringValue = place()
        let tab = tabs.selected
        details.isHidden = settings != nil || tab != .details
        computerPane.isHidden = tab != .computer
        settings?.showSection(tab)
        computer.watchesScreen = tab == .computer
        // The app's plan read, or the Cloud service's own answer for this Chief (it holds before the app's read answers).
        let gate = Self.gate(paid: paid() || computer.entitled, cloudChief: cloudChief(), hasComputer: computer.shown != nil,
                             machine: settings?.attachedMachine != nil)
        shownGate = gate
        gateBox.isHidden = gate == nil
        showGate(gate)
        controlBar.redraw()
        followControl()
    }

    @objc func closeTab() { onClose() }
    @objc func openSettings() { onSettings() }
}
