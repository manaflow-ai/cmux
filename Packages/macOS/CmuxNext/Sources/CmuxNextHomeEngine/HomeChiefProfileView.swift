public import AppKit
import CmuxNextDesign

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
/// the upsell, for a Chief of this Mac it offers the move or a Cloud machine, and until the Chief sets
/// one up it says how to ask. Under a live screen the control bar says who drives and changes it.
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
    /// The expanded page's widest column: the screen as large as the pane allows, up to this.
    static let expandedWidth: CGFloat = 960
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
    /// Upgrade, on the paywall.
    public var onUpgrade: () -> Void = {}
    /// Move to Cloud, for a Chief of this Mac.
    public var onMoveToCloud: () -> Void = {}
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
    private(set) lazy var closeButton = HomeChiefCardCloseButton(label: HomeEngineStrings.closeCard, target: self, action: #selector(closeTab))
    /// What the tab shows now.
    private(set) var shownGate: Gate?
    /// The person's inputs, sent one after another.
    var sending: Task<Void, Never>?
    /// The panel or page is on screen: the computer and the card's sections read.
    private(set) var isOpen = false

    public init(settings: HomeChiefSettingsView? = nil) {
        self.settings = settings
        avatar = settings?.avatarButton ?? HomeChiefAvatarButton(size: Self.avatarSize)
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(settings == nil ? "cmux.home.chief.profile" : "cmux.home.chief.profile.panel")
        buildColumn()
        tabs.shown = settings == nil ? [.details, .computer] : HomeChiefProfileTab.allCases
        tabs.select(settings == nil ? .computer : .details)
        tabs.onPick = { [weak self] _ in self?.refresh() }
        computer.onResize = { [weak self] in self?.refresh() }
        computer.onStatus = { [weak self] in self?.refresh() }
        controlBar.chief = { [weak self] in self?.name() ?? "" }
        controlBar.onChange = { [weak self] in self?.followControl() }
        settings?.onResize = { [weak self] in self?.needsLayout = true }
        settings?.onComputerShown = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated public override var isFlipped: Bool { true }

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
            sending?.cancel()
            sending = nil
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
        let gate = Self.gate(paid: paid(), cloudChief: cloudChief(), hasComputer: computer.shown != nil,
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
